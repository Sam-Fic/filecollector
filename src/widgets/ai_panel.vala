/* AI 助手聊天面板.
 *
 * 与多平台版本 ai_panel.py 行为 1:1:
 *  - 顶部: AI 助手标题
 *  - 中部: 聊天气泡 (用户右对齐蓝色, 助手左对齐白底, 系统居中黄色, 工具调用可折叠)
 *  - 底部: 多行输入框 + 发送/清空按钮
 *  - 状态行: 模型名 + 当前状态
 *
 * API 调用走 GLib.Thread + Worker, 不阻塞主线程.
 * 工具调用由主窗口注入的 tool_executor 回调执行; 这里只负责消息展示和对话循环.
 *
 * UI 风格: 与现有 left/middle/right 三栏卡片 (css "card") 完全一致 —
 * Box css="card" + panel-title 标题.
 */

using GLib;
using Gtk;
using Adw;
using Gee;
using Json;
using AI;

public class AIMessage : GLib.Object {
    public string role;       // "user" | "assistant" | "system" | "tool"
    public string content;    // 纯文本 (markdown 不渲染, 跟现有三栏的纯文本风格一致)
    public string tool_name;  // tool 专用
    public string tool_args_repr;  // tool 专用
    public string tool_result;     // tool 专用
    public bool expanded;
    public int undo_token = -1;

    public AIMessage (string r, string c) {
        role = r;
        content = c ?? "";
    }
}


public class AIPanel : GLib.Object {
    private Gtk.Window? parent_window;

    // 控件
    private Gtk.Box root_box;
    private Gtk.Box chat_container;     // 直接放气泡的 Box
    private Gtk.ScrolledWindow chat_scroll;
    private Gtk.TextView input_view;
    private Gtk.Button btn_send;
    private Gtk.Label lbl_send;
    private Gtk.Image send_icon;
    private Gtk.Button btn_clear;
    private Gtk.Button btn_scroll_bottom;
    private Gtk.Label lbl_status;
    private Gtk.Spinner status_spinner;

    private Gtk.Frame completion_frame;
    private Gtk.ListBox completion_list;
    private Gtk.Label lbl_model;

    // 状态
    private AIClient? client;
    private string system_prompt_override = "";
    private AIToolExecutor? tool_executor;
    private AIStateProvider? state_provider;

    public signal int get_undo_token ();
    public signal void revert_to_undo_token (int token);
    public signal void template_triggered (string header, string footer);
    // agent 循环正常结束 (最终回复不含工具调用) 时触发;
    // summary 是最终回复的首行单行摘要 (可能为空串), 供任务完成通知使用
    public signal void task_completed (string summary);

    private GLib.Thread<void>? worker_thread = null;
    private bool busy = false;
    private bool stop_requested = false;
    // panel 已被 shutdown 且其 widget 不再安全访问 (窗口关闭时设置)。
    // 异步回调切回主线程后必须先检查此标志, 避免访问已销毁的 widget。
    private bool panel_destroyed = false;
    private bool pending_welcome = true;
    private bool ai_enabled = false;
    private GLib.Cancellable? request_cancellable = null;
    // 用户是否停留在底部附近 (用于判断是否自动滚动)
    private bool auto_scroll = true;
    // 标记正在 rerender, 抑制 adj.changed 的自动滚动 (由 rerender 自行处理)
    private bool is_rerendering = false;

    private Gee.ArrayList<Json.Node> messages = new Gee.ArrayList<Json.Node> ();
    private Gee.ArrayList<AIMessage> rendered = new Gee.ArrayList<AIMessage> ();
    private int tool_counter = 0;

    // messages 在 worker 线程 (on_api_finished) 和主线程 (rebuild_system_message,
    // send_user_message, on_clear_chat) 之间并发读写, 必须用锁保护
    private GLib.Mutex messages_lock = GLib.Mutex ();

    // 由主窗口创建并配置; 本身只是个 widget 工厂
    public AIPanel (Gtk.Window? parent) {
        this.parent_window = parent;
    }

    public Gtk.Widget build_widget () {
        root_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

        // 标题不在此处: 由主窗口的 build_ai_split_view 用标准 Adw.HeaderBar 提供
        // (与左侧 Workspaces 侧栏同构), headerbar 高度与主标题栏一致,
        // 聊天区顶边因此天然与三卡片的顶线对齐, 无需手工 margin 补偿.

        // ── 聊天区 ──
        chat_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        chat_container.margin_start = 0;
        chat_container.margin_end = 0;
        chat_container.margin_top = 0;
        chat_container.margin_bottom = 6;
        chat_container.set_homogeneous (false);

        // 容器底部用 Box 撑开, 让内容少时也保持顶部对齐
        var chat_alignment = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        chat_alignment.append (chat_container);
        // 末尾 stretch
        var tail = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        tail.hexpand = true;
        tail.vexpand = true;
        chat_alignment.append (tail);

        chat_scroll = new Gtk.ScrolledWindow ();
        chat_scroll.set_child (chat_alignment);
        chat_scroll.set_vexpand (true);
        chat_scroll.set_hexpand (true);
        // 滚动条与滚动区分隔线整体内缩 12, 与其他卡片左右内边距对齐
        chat_scroll.set_margin_start (12);
        chat_scroll.set_margin_end (12);
        chat_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);

        // 滚动到底部按钮 (悬浮在聊天区右下角, 不在底部时显示)
        btn_scroll_bottom = new Gtk.Button.from_icon_name ("go-down-symbolic");
        btn_scroll_bottom.add_css_class ("circular");
        btn_scroll_bottom.set_tooltip_text (_("Scroll to Bottom"));
        btn_scroll_bottom.set_halign (Gtk.Align.END);
        btn_scroll_bottom.set_valign (Gtk.Align.END);
        // 12 (scroll 内缩) + 8 (原视觉边距) = 20, 与内缩后的滚动区右下角对齐
        btn_scroll_bottom.set_margin_end (20);
        btn_scroll_bottom.set_margin_bottom (8);
        btn_scroll_bottom.set_visible (false);
        btn_scroll_bottom.clicked.connect (() => {
            scroll_to_bottom (true);
        });
        // 用 Overlay 让按钮悬浮在 ScrolledWindow 上
        var chat_overlay = new Gtk.Overlay ();
        chat_overlay.set_child (chat_scroll);
        chat_overlay.add_overlay (btn_scroll_bottom);
        root_box.append (chat_overlay);

        // 监听滚动位置: 判断用户是否在底部附近
        var adj = chat_scroll.get_vadjustment ();
        adj.changed.connect (() => {
            // rerender 期间不自动滚动, 由 rerender 自行恢复位置
            if (auto_scroll && !is_rerendering) {
                scroll_to_bottom (false);
            }
            update_scroll_bottom_btn ();
        });
        adj.value_changed.connect (() => {
            update_auto_scroll ();
            update_scroll_bottom_btn ();
        });

        // ── 补全列表 (默认隐藏, 出现在输入框上方) ──
        completion_frame = new Gtk.Frame (null);
        completion_frame.add_css_class ("card");
        completion_frame.add_css_class ("ai-input-frame");
        completion_frame.margin_start = 12;
        completion_frame.margin_end = 12;
        completion_frame.margin_bottom = 4;
        completion_frame.visible = false;

        completion_list = new Gtk.ListBox ();
        completion_list.add_css_class ("boxed-list");
        completion_list.set_selection_mode (Gtk.SelectionMode.SINGLE);

        var completion_scroll = new Gtk.ScrolledWindow ();
        completion_scroll.set_child (completion_list);
        completion_scroll.set_min_content_height (150);
        completion_scroll.set_max_content_height (200);
        completion_scroll.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        completion_frame.set_child (completion_scroll);
        root_box.append (completion_frame);

        // ── 输入区 ──
        var input_frame = new Gtk.Frame (null);
        input_frame.add_css_class ("card");
        input_frame.add_css_class ("ai-input-frame");
        input_frame.margin_start = 12;
        input_frame.margin_end = 12;
        input_frame.margin_top = 2;
        input_frame.margin_bottom = 6;

        var input_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        input_box.margin_start = 6;
        input_box.margin_end = 6;
        input_box.margin_top = 6;
        input_box.margin_bottom = 6;

        input_view = new Gtk.TextView ();
        input_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        input_view.set_top_margin (4);
        input_view.set_bottom_margin (4);
        input_view.set_left_margin (6);
        input_view.set_right_margin (6);
        input_view.set_size_request (-1, 80);
        // GTK4 中 Gtk.TextView 没有 set_placeholder_text; 用 overlay 自行实现
        var input_overlay = new Gtk.Overlay ();
        input_overlay.set_child (input_view);
        var placeholder_lbl = new Gtk.Label (_("Enter a command, Enter for new line, Ctrl+Enter to send"));
        placeholder_lbl.add_css_class ("dim-label");
        placeholder_lbl.add_css_class ("ai-placeholder");
        placeholder_lbl.set_wrap (true);
        placeholder_lbl.set_wrap_mode (Pango.WrapMode.WORD_CHAR);
        placeholder_lbl.set_xalign (0);
        placeholder_lbl.set_halign (Gtk.Align.START);
        placeholder_lbl.set_valign (Gtk.Align.START);
        // 跟 TextView 自身边距一致, 让占位文字与光标基线对齐
        placeholder_lbl.set_margin_start (6);
        placeholder_lbl.set_margin_top (4);
        // 关键: 让占位标签不接收鼠标事件, 否则会盖在 TextView 上拦截点击
        placeholder_lbl.set_can_target (false);
        placeholder_lbl.set_can_focus (false);
        input_overlay.add_overlay (placeholder_lbl);
        input_view.get_buffer ().changed.connect (() => {
            Gtk.TextIter s, e;
            input_view.get_buffer ().get_bounds (out s, out e);
            placeholder_lbl.visible = input_view.get_buffer ().get_text (s, e, false).length == 0;
        });
        input_box.append (input_overlay);
        // ── 快捷键 ──
        // Enter 键不在 EventControllerKey 中处理, 而是通过 buffer.changed 信号检测:
        // 当 IME 未消费 Enter 时, GtkSource.View 会插入换行, 我们检测到后删除换行并触发发送。
        // 这样完全不干扰 IME 的候选词确认。

        var key = new Gtk.EventControllerKey ();
        key.key_pressed.connect ((keyval, keycode, state) => {
            // 补全列表导航
            if (completion_frame.visible) {
                if (keyval == Gdk.Key.Down) {
                    move_completion_selection (1);
                    return true;
                } else if (keyval == Gdk.Key.Up) {
                    move_completion_selection (-1);
                    return true;
                } else if (keyval == Gdk.Key.Escape) {
                    hide_completion ();
                    return true;
                }
            }
            return false;
        });
        input_view.add_controller (key);

        // 通过 buffer.changed 检测 Enter (换行插入)
        // 使用标记防止递归
        bool suppress_send = false;
        bool ctrl_enter_pressed = false;

        // Ctrl+Enter 标记: 在 key handler 中检测
        var ctrl_key = new Gtk.EventControllerKey ();
        ctrl_key.key_pressed.connect ((keyval, keycode, state) => {
            if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter) &&
                (state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                ctrl_enter_pressed = true;
            }
            return false;
        });
        input_view.add_controller (ctrl_key);

        input_view.get_buffer ().changed.connect (() => {
            if (suppress_send) return;

            Gtk.TextBuffer buf = input_view.get_buffer ();
            Gtk.TextIter end_iter;
            buf.get_end_iter (out end_iter);

            // 检查末尾是否有换行
            if (buf.get_char_count () == 0) return;
            Gtk.TextIter prev = end_iter;
            prev.backward_char ();
            string last_char = prev.get_text (end_iter);
            if (last_char != "\n") return;

            // 补全列表可见时, Enter 确认补全
            if (completion_frame.visible) {
                var selected = completion_list.get_selected_row ();
                if (selected != null) {
                    suppress_send = true;
                    buf.delete (ref prev, ref end_iter);
                    suppress_send = false;
                    apply_completion (selected);
                    return;
                }
            }

            // Ctrl+Enter = 发送 (删除换行, 触发发送)
            if (ctrl_enter_pressed) {
                ctrl_enter_pressed = false;
                suppress_send = true;
                buf.delete (ref prev, ref end_iter);
                suppress_send = false;
                on_send_or_stop ();
                return;
            }

            // Enter = 换行 (GtkTextView 已自动插入换行, 这里什么都不做)
        });

        // 监听输入变化以触发补全
        input_view.get_buffer ().changed.connect (on_input_changed);

        // 按钮行
        var btn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        btn_clear = new Gtk.Button.from_icon_name ("user-trash-symbolic");
        btn_clear.set_tooltip_text (_("Clear Chat"));
        btn_clear.set_size_request (-1, -1);
        btn_clear.clicked.connect (on_clear_chat);
        btn_row.append (btn_clear);

        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        spacer.hexpand = true;
        btn_row.append (spacer);

        var send_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        send_box.halign = Gtk.Align.CENTER;
        send_icon = new Gtk.Image.from_icon_name ("mail-send-symbolic");
        send_box.append (send_icon);
        lbl_send = new Gtk.Label (_("Send"));
        send_box.append (lbl_send);

        btn_send = new Gtk.Button ();
        btn_send.set_child (send_box);
        btn_send.add_css_class ("suggested-action");
        btn_send.clicked.connect (on_send_or_stop);
        btn_row.append (btn_send);
        input_box.append (btn_row);

        input_frame.set_child (input_box);
        root_box.append (input_frame);

        // ── 状态行 ──
        var status_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        status_row.margin_start = 12;
        status_row.margin_end = 12;
        status_row.margin_bottom = 8;
        status_spinner = new Gtk.Spinner ();
        status_spinner.visible = false;
        status_spinner.valign = Gtk.Align.CENTER;
        status_row.append (status_spinner);
        lbl_status = new Gtk.Label (null);
        lbl_status.halign = Gtk.Align.START;
        lbl_status.add_css_class ("dim-label");
        lbl_status.add_css_class ("caption");
        lbl_status.hexpand = true;
        status_row.append (lbl_status);
        lbl_model = new Gtk.Label (null);
        lbl_model.halign = Gtk.Align.END;
        lbl_model.add_css_class ("dim-label");
        lbl_model.add_css_class ("caption");
        status_row.append (lbl_model);
        root_box.append (status_row);

        update_status ();
        return root_box;
    }

    // 公共 API: 主窗口初始化或设置变更时调用
    public void configure (
        ConfigManager.AISettings ai,
        AIToolExecutor executor,
        AIStateProvider provider
    ) {
        this.tool_executor = executor;
        this.state_provider = provider;

        // 显式类型 + 不同变量名, 避免字段遮蔽与 GLib.Object 推断问题
        ConfigManager.AISettings s = ai;
        string base_url_str = s.base_url;
        string api_key_str = s.api_key;
        string model_str = s.model;
        string sp_str = s.system_prompt_override;
        if (base_url_str == null) base_url_str = "";
        if (api_key_str == null) api_key_str = "";
        if (model_str == null) model_str = "";
        if (sp_str == null) sp_str = "";
        this.system_prompt_override = sp_str.strip ();

        base_url_str = base_url_str.strip ();
        api_key_str = api_key_str.strip ();
        model_str = model_str.strip ();
        double timeout_v = s.timeout > 0 ? s.timeout : 60.0;

        lbl_model.set_text (model_str.length > 0 ? model_str : _("No model configured"));
        bool has_config = base_url_str.length > 0 && api_key_str.length > 0 && model_str.length > 0;

        bool was_enabled = this.ai_enabled;
        this.ai_enabled = ai.enabled;

        if (has_config && ai.enabled) {
            client = new AIClient (base_url_str, api_key_str, model_str, timeout_v);
            if (!was_enabled && ai.enabled) {
                pending_welcome = true;
            }
        } else {
            client = null;
        }
        bool was_first = pending_welcome;
        update_status ();
        if (ai.enabled && was_first) {
            pending_welcome = false;
            render_assistant (_("Hello, I am the AI orchestration assistant. Tell me which files you want to collect and I will help you organize them.\nFor example: \"Add all Python files under src, then insert a task description at the beginning.\""));
        }
    }

    public void shutdown () {
        stop_requested = true;
        panel_destroyed = true;
        if (request_cancellable != null) {
            request_cancellable.cancel ();
        }
        // 不阻塞主线程等待 HTTP 请求超时。
        // cancel() 会令 libsoup 中断请求, worker 线程将自行退出。
        // 异步 run_worker 回调切回主线程后会通过 panel_destroyed 检查提前返回,
        // 不会再访问已销毁的 widget。
        worker_thread = null;
    }

    // 供外部 (如 FileCollectorWindow) 查询 AI 是否已被用户停止
    public bool is_stop_requested () {
        return stop_requested;
    }


    // ─── 渲染 ────────────────────────────────────────────────────────────

    private void render_user (string text, int token = -1) {
        var stripped = text.strip ();
        if (stripped.length == 0) return;
        var msg = new AIMessage ("user", stripped);
        msg.undo_token = token;
        rendered.add (msg);
        rerender ();
    }

    private void render_assistant (string text) {
        var stripped = text.strip ();
        // 内容为空或纯空白时不渲染气泡 (避免工具调用间出现空白气泡)
        if (stripped.length == 0) return;
        var msg = new AIMessage ("assistant", stripped);
        rendered.add (msg);
        rerender ();
    }

    private void render_system (string text) {
        var stripped = text.strip ();
        if (stripped.length == 0) return;
        var msg = new AIMessage ("system", stripped);
        rendered.add (msg);
        rerender ();
    }

    private void render_tool (string name, string args_repr, string result) {
        tool_counter++;
        var msg = new AIMessage ("tool", "");
        msg.tool_name = name;
        msg.tool_args_repr = args_repr;
        msg.tool_result = result ?? "OK";
        msg.expanded = false;
        rendered.add (msg);
        rerender ();
    }

    // 清洗 UTF-8: 用 replacement character 替换无效字节, 避免 Pango 警告
    private string sanitize_utf8 (string? text) {
        return UIHelpers.sanitize_utf8 (text);
    }

    private void rerender () {
        // 保存当前滚动位置 (相对底部的偏移), 用于重建后恢复
        var adj_before = chat_scroll.get_vadjustment ();
        double saved_offset_from_bottom = -1;
        if (adj_before != null) {
            saved_offset_from_bottom = adj_before.get_upper () - adj_before.get_value () - adj_before.get_page_size ();
            if (saved_offset_from_bottom < 0) saved_offset_from_bottom = 0;
        }

        // 标记正在 rerender, 抑制 adj.changed 的自动滚动
        is_rerendering = true;

        // 清空旧气泡
        UIHelpers.clear_container (chat_container);
        foreach (var msg in rendered) {
            chat_container.append (build_bubble (msg));
        }
        // 重建后恢复滚动位置: 工具展开/折叠时不应该跳动
        // 用 Idle 确保布局完成后再设置
        GLib.Idle.add (() => {
            is_rerendering = false;
            var a = chat_scroll.get_vadjustment ();
            if (a != null) {
                if (auto_scroll && saved_offset_from_bottom < 30) {
                    // 用户原本在底部附近, 滚动到底部
                    a.set_value (a.get_upper () - a.get_page_size ());
                } else if (saved_offset_from_bottom >= 0) {
                    // 用户不在底部, 保持相对底部的位置
                    double new_value = a.get_upper () - a.get_page_size () - saved_offset_from_bottom;
                    if (new_value < 0) new_value = 0;
                    a.set_value (new_value);
                }
            }
            update_scroll_bottom_btn ();
            return GLib.Source.REMOVE;
        });
    }

    // 滚动到底部. force=true 时强制滚动并重置 auto_scroll.
    private void scroll_to_bottom (bool force) {
        if (force) {
            auto_scroll = true;
        }
        var adj = chat_scroll.get_vadjustment ();
        if (adj == null) return;
        // 用 Idle 确保在布局更新后再滚动
        GLib.Idle.add (() => {
            var a = chat_scroll.get_vadjustment ();
            if (a != null) {
                a.set_value (a.get_upper () - a.get_page_size ());
            }
            update_scroll_bottom_btn ();
            return GLib.Source.REMOVE;
        });
    }

    // 根据当前滚动位置更新 auto_scroll 标志.
    // 在底部附近 (30px 容差) 视为"在底部", 允许自动滚动.
    private void update_auto_scroll () {
        var adj = chat_scroll.get_vadjustment ();
        if (adj == null) return;
        double current = adj.get_value ();
        double upper = adj.get_upper ();
        double page = adj.get_page_size ();
        double bottom = upper - page;
        auto_scroll = (current >= bottom - 30);
    }

    // 根据是否在底部更新滚动按钮的可见性
    private void update_scroll_bottom_btn () {
        var adj = chat_scroll.get_vadjustment ();
        if (adj == null) {
            btn_scroll_bottom.set_visible (false);
            return;
        }
        double current = adj.get_value ();
        double upper = adj.get_upper ();
        double page = adj.get_page_size ();
        double bottom = upper - page;
        // 内容不足以滚动时隐藏按钮
        if (upper <= page + 1) {
            btn_scroll_bottom.set_visible (false);
        } else {
            btn_scroll_bottom.set_visible (current < bottom - 30);
        }
    }

    private Gtk.Widget build_bubble (AIMessage msg) {
        // 外层: 决定左/右/居中对齐
        var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        outer.set_size_request (-1, -1);

        var bubble = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        bubble.add_css_class ("ai-bubble");
        switch (msg.role) {
            case "user":
                bubble.add_css_class ("card");
                break;
            case "assistant":
                bubble.add_css_class ("ai-bubble-assistant");
                break;
            case "system":
                bubble.add_css_class ("ai-bubble-system");
                break;
            case "tool":
                bubble.add_css_class ("ai-bubble-tool");
                break;
        }

        switch (msg.role) {
            case "user": {
                var hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
                hbox.hexpand = true;

                var label = new Gtk.Label (sanitize_utf8 (msg.content));
                label.xalign = 0;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.selectable = true;
                label.hexpand = true;
                label.halign = Gtk.Align.FILL;
                label.add_css_class ("ai-bubble-content");
                hbox.append (label);

                var revert_btn = new Gtk.Button.from_icon_name ("edit-undo-symbolic");
                revert_btn.add_css_class ("flat");
                revert_btn.add_css_class ("ai-revert-btn");
                revert_btn.set_tooltip_text (_("Revert this message and all subsequent AI replies and operations"));
                revert_btn.valign = Gtk.Align.CENTER;
                revert_btn.halign = Gtk.Align.END;
                revert_btn.margin_start = 8;
                revert_btn.opacity = 0.6;

                int captured_token = msg.undo_token;
                string captured_text = msg.content;
                revert_btn.clicked.connect (() => {
                    on_revert_requested (captured_token, captured_text);
                });

                hbox.append (revert_btn);
                bubble.append (hbox);
                break;
            }
            case "assistant": {
                // 用 Markdown 渲染 (cmark AST → GTK widget 树)
                var md = new MarkdownView (msg.content);
                md.add_css_class ("ai-bubble-content");
                bubble.append (md);
                break;
            }
            case "system": {
                var label = new Gtk.Label (sanitize_utf8 (msg.content));
                label.xalign = 0;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.selectable = true;
                label.hexpand = true;
                label.halign = Gtk.Align.FILL;
                label.add_css_class ("ai-bubble-content");
                label.valign = Gtk.Align.CENTER;
                bubble.append (label);
                break;
            }
            case "tool": {
                // 工具调用卡片: 头部 (icon + name + args + action) + body/preview (可折叠)
                var header_btn = new Gtk.Button ();
                header_btn.add_css_class ("flat");
                header_btn.add_css_class ("ai-tool-header");
                header_btn.set_size_request (-1, 32);
                header_btn.halign = Gtk.Align.FILL;

                var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);

                // 用 GTK 原生 disclosure 图标 (与文件树文件夹展开箭头同款)
                var arrow = new Gtk.Image ();
                arrow.icon_name = msg.expanded ? "pan-down-symbolic" : "pan-end-symbolic";
                arrow.add_css_class ("ai-tool-arrow");
                arrow.valign = Gtk.Align.CENTER;
                header_box.append (arrow);

                var name_lbl = new Gtk.Label (sanitize_utf8 (msg.tool_name));
                name_lbl.add_css_class ("ai-tool-name");
                name_lbl.valign = Gtk.Align.CENTER;
                header_box.append (name_lbl);

                var args_lbl = new Gtk.Label (sanitize_utf8 (msg.tool_args_repr));
                args_lbl.add_css_class ("ai-tool-args");
                args_lbl.add_css_class ("dim-label");
                args_lbl.valign = Gtk.Align.CENTER;
                args_lbl.ellipsize = Pango.EllipsizeMode.END;
                args_lbl.hexpand = true;
                args_lbl.halign = Gtk.Align.START;
                header_box.append (args_lbl);

                header_btn.set_child (header_box);

                // Body (展开时显示完整结果)
                var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
                body.add_css_class ("ai-tool-body");
                var result_lbl = new Gtk.Label (sanitize_utf8 (msg.tool_result ?? ""));
                result_lbl.xalign = 0;
                result_lbl.yalign = 0;
                result_lbl.wrap = true;
                result_lbl.wrap_mode = Pango.WrapMode.WORD_CHAR;
                result_lbl.selectable = true;
                result_lbl.add_css_class ("ai-tool-result");
                body.append (result_lbl);

                // Preview (折叠时显示截断预览)
                var preview = msg.tool_result ?? "";
                if (preview.length > 80) preview = UIHelpers.truncate_utf8 (preview, 80) + "…";
                var preview_lbl = new Gtk.Label (sanitize_utf8 (preview));
                preview_lbl.xalign = 0;
                preview_lbl.wrap = true;
                preview_lbl.add_css_class ("ai-tool-preview");
                preview_lbl.add_css_class ("dim-label");

                // 初始可见性
                body.set_visible (msg.expanded);
                preview_lbl.set_visible (!msg.expanded);

                // 展开/折叠: 直接切换可见性, 不重建整个聊天区
                header_btn.clicked.connect (() => {
                    msg.expanded = !msg.expanded;
                    // 保存头部在视口中的相对位置, 展开后恢复
                    var adj_save = chat_scroll.get_vadjustment ();
                    double saved_value = adj_save != null ? adj_save.get_value () : 0;
                    body.set_visible (msg.expanded);
                    preview_lbl.set_visible (!msg.expanded);
                    arrow.icon_name = msg.expanded ? "pan-down-symbolic" : "pan-end-symbolic";

                    // 展开时保持头部位置不动 (内容向下展开)
                    if (msg.expanded) {
                        GLib.Idle.add (() => {
                            var a = chat_scroll.get_vadjustment ();
                            if (a != null) {
                                a.set_value (saved_value);
                            }
                            update_scroll_bottom_btn ();
                            return GLib.Source.REMOVE;
                        });
                    }
                });

                bubble.append (header_btn);
                bubble.append (body);
                bubble.append (preview_lbl);
                break;
            }
        }

        switch (msg.role) {
            case "user":
            case "assistant":
            case "system":
            case "tool":
            default:
                // 所有气泡都填满整个宽度, 不再左右留白自适应
                bubble.hexpand = true;
                bubble.halign = Gtk.Align.FILL;
                outer.append (bubble);
                break;
        }

        return outer;
    }


    // ─── 交互 ────────────────────────────────────────────────────────────

    private void on_send_or_stop () {
        if (busy) {
            request_stop ();
            return;
        }
        on_send ();
    }

    private void request_stop () {
        stop_requested = true;
        if (request_cancellable != null) {
            request_cancellable.cancel ();
        }
        lbl_status.set_text (_("Stopped"));
        // 停止时保留已流式生成的部分回复 (主流聊天应用行为):
        // set_busy(false) 会移除流式气泡, 先取出文本, 再作为正式 assistant
        // 消息渲染并写入历史, 保证上下文连贯
        string? partial = null;
        if (streaming_label != null) {
            string text = streaming_label.label;
            if (text.strip ().length > 0) partial = text;
        }
        set_busy (false);
        if (partial != null) {
            messages_lock.lock ();
            messages.add (build_chat_node ("assistant", partial));
            messages_lock.unlock ();
            render_assistant (partial);
        }
    }

    private void on_input_changed () {
        Gtk.TextIter cursor_iter;
        input_view.get_buffer ().get_iter_at_mark (out cursor_iter, input_view.get_buffer ().get_insert ());
        Gtk.TextIter line_start = cursor_iter;
        line_start.set_line_offset (0);
        string line_text = line_start.get_text (cursor_iter);

        if (line_text.has_prefix ("/t") || line_text.has_prefix ("/template")) {
            string query = "";
            if (line_text.has_prefix ("/template ")) {
                query = line_text.substring (10).strip ();
            } else if (line_text.has_prefix ("/t ")) {
                query = line_text.substring (3).strip ();
            } else if (line_text == "/t" || line_text == "/template") {
                query = "";
            } else {
                query = line_text.has_prefix ("/template") ? line_text.substring (9) : line_text.substring (2);
            }
            show_completion (query);
        } else {
            hide_completion ();
        }
    }

    private void show_completion (string query) {
        while (completion_list.get_first_child () != null) {
            completion_list.remove (completion_list.get_first_child ());
        }

        var templates = ConfigManager.load_templates ();
        int match_count = 0;

        foreach (var tpl in templates) {
            if (query == "" || tpl.id.down ().contains (query.down ()) || tpl.name.down ().contains (query.down ())) {
                var row = new Adw.ActionRow ();
                row.set_title (tpl.name);
                row.set_subtitle ("/" + tpl.id + "  •  " + tpl.description);
                row.set_activatable (true);
                row.set_data<string> ("template_id", tpl.id);

                var click = new Gtk.GestureClick ();
                click.set_button (Gdk.BUTTON_PRIMARY);
                click.pressed.connect ((n_press, x, y) => {
                    apply_completion (row);
                });
                row.add_controller (click);

                completion_list.append (row);
                match_count++;
            }
        }

        if (match_count > 0) {
            completion_frame.visible = true;
            completion_list.select_row (completion_list.get_first_child () as Gtk.ListBoxRow);
        } else {
            hide_completion ();
        }
    }

    private void hide_completion () {
        completion_frame.visible = false;
    }

    private void move_completion_selection (int direction) {
        var selected = completion_list.get_selected_row ();
        if (selected == null) {
            if (direction > 0) {
                completion_list.select_row (completion_list.get_first_child () as Gtk.ListBoxRow);
            }
            return;
        }
        Gtk.Widget? next = direction > 0 ? selected.get_next_sibling () : selected.get_prev_sibling ();
        if (next != null && next is Gtk.ListBoxRow) {
            completion_list.select_row ((Gtk.ListBoxRow) next);
        }
    }

    private void apply_completion (Gtk.ListBoxRow row) {
        string id = row.get_data<string> ("template_id");
        hide_completion ();
        input_view.get_buffer ().set_text ("", 0);
        execute_template_by_id (id);
    }

    private void execute_template_by_id (string id) {
        var templates = ConfigManager.load_templates ();
        PromptTemplate? tpl = null;
        foreach (var t in templates) {
            if (t.id == id) { tpl = t; break; }
        }

        if (tpl == null) {
            render_system (_("Template not found: %s").printf (id));
            return;
        }

        template_triggered (tpl.header_text, tpl.footer_text);
        send_user_message (_("[Apply template: %s]\n%s").printf (tpl.name, tpl.ai_prompt));
    }

    private void on_send () {
        if (busy) return;

        Gtk.TextBuffer buf = input_view.get_buffer ();
        Gtk.TextIter start, end;
        buf.get_bounds (out start, out end);
        string text = buf.get_text (start, end, false).strip ();
        if (text.length == 0) return;

        if (text.has_prefix ("/template ") || text.has_prefix ("/t ") || text == "/template" || text == "/t") {
            buf.set_text ("", 0);
            hide_completion ();
            string[] parts = text.split (" ", 2);
            string id = parts.length > 1 ? parts[1].strip () : "";
            execute_template_by_id (id);
            return;
        }

        if (client == null) {
            if (!ai_enabled) {
                render_system (_("Please enable the AI assistant in Settings → AI Settings first."));
            } else {
                render_system (_("Please configure the API in Settings → AI Settings first."));
            }
            return;
        }

        buf.set_text ("", 0);
        send_user_message (text);
    }

    private void on_clear_chat () {
        end_streaming ();
        UIHelpers.clear_container (chat_container);
        messages_lock.lock ();
        messages.clear ();
        messages_lock.unlock ();
        rendered.clear ();
        tool_counter = 0;
        pending_welcome = true;
    }

    private void on_revert_requested (int token, string text) {
        if (token < 0) return;

        var dialog = new Adw.AlertDialog (
            _("Confirm Revert"),
            _("This will undo all AI replies after this message and modifications to the file list. Continue?")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("revert", _("Revert"));
        dialog.set_response_appearance ("revert", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "revert") {
                if (busy) {
                    request_stop ();
                }

                revert_to_undo_token (token);

                int revert_index = -1;
                for (int i = 0; i < rendered.size; i++) {
                    if (rendered.get (i).undo_token == token && rendered.get (i).role == "user") {
                        revert_index = i;
                        break;
                    }
                }

                if (revert_index >= 0) {
                    while (rendered.size > revert_index) {
                        rendered.remove_at (rendered.size - 1);
                    }

                    messages_lock.lock ();
                    messages.clear ();
                    messages_lock.unlock ();

                    rerender ();

                    input_view.get_buffer ().set_text (text, -1);
                    input_view.grab_focus ();
                }
            }
            dialog.destroy ();
        });

        dialog.present (parent_window);
    }


    // ─── 对话循环 ────────────────────────────────────────────────────────

    // build_system_prompt / format_tool_args / parse_args 三个纯函数已移至
    // services/ai_prompt_builder.vala (AIPromptBuilder 类), 让 ai_panel 专注于
    // UI 与对话编排, prompt 模板构造与 tool args 格式化交给独立可测试的纯逻辑.

    private void send_user_message (string text) {
        int token = get_undo_token ();
        rebuild_system_message ();
        messages_lock.lock ();
        messages.add (build_chat_node ("user", text));
        messages_lock.unlock ();
        render_user (text, token);
        next_turn ();
    }

    private void rebuild_system_message () {
        // 移除已有 system 消息 (加锁保护并发读写)
        messages_lock.lock ();
        var keep = new Gee.ArrayList<Json.Node> ();
        foreach (var m in messages) {
            if (get_role (m) != "system") keep.add (m);
        }
        messages = keep;
        messages_lock.unlock ();
        if (state_provider == null) return;
        var snap = state_provider ();
        string prompt;
        if (system_prompt_override.length > 0) {
            prompt = system_prompt_override + "\n\n" + AIPromptBuilder.build_system_prompt (snap);
        } else {
            prompt = AIPromptBuilder.build_system_prompt (snap);
        }
        messages_lock.lock ();
        messages.insert (0, build_chat_node ("system", prompt));
        messages_lock.unlock ();
    }

    private static string get_role (Json.Node n) {
        if (n.get_node_type () != Json.NodeType.OBJECT) return "";
        return n.get_object ().get_string_member_with_default ("role", "");
    }

    private static Json.Node build_chat_node (string role, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", role);
        o.set_string_member ("content", content ?? "");
        return AI.SchemaHelper.obj_to_node (o);
    }

    private void next_turn () {
        // 在主线程上快照 client 引用, 避免worker线程读取 client 字段时
        // 与 configure() 并发写入竞态 (configure 可能从主线程设置 client = null
        // 或 client = new AIClient(...), 若 worker 直接读字段可能看到 torn read
        // 或使用已释放的旧 client).
        AIClient? client_snapshot = client;
        if (client_snapshot == null) return;
        set_busy (true);

        // 浅拷贝消息列表传给 worker 线程, 避免读写竞争 (加锁保护遍历)
        var msgs_copy = new Gee.ArrayList<Json.Node> ();
        messages_lock.lock ();
        foreach (var m in messages) msgs_copy.add (m);
        messages_lock.unlock ();

        stop_requested = false;
        request_cancellable = new GLib.Cancellable ();
        worker_thread = new GLib.Thread<void> ("ai-worker", () => {
            run_worker.begin (msgs_copy, client_snapshot);
        });
    }

    private async void run_worker (Gee.ArrayList<Json.Node> msgs, AIClient client_snapshot) {
        // 使用主线程快照的 client 引用, 不直接读取 this.client 字段,
        // 避免与 configure() 的并发写入竞态。
        AIClient local = client_snapshot;
        if (local == null) {
            on_api_failed (_("Client not configured"));
            return;
        }
        try {
            var result = local.chat_stream (msgs, build_full_tool_schema (), request_cancellable, (piece) => {
                // 回调在 worker 线程触发, 切回主线程更新流式气泡
                GLib.Idle.add (() => {
                    if (!panel_destroyed && !stop_requested) {
                        append_streaming_text (piece);
                    }
                    return GLib.Source.REMOVE;
                });
            });
            if (stop_requested || panel_destroyed) {
                if (!panel_destroyed) {
                    GLib.Idle.add (() => { set_busy (false); return GLib.Source.REMOVE; });
                }
                return;
            }
            yield on_api_finished (result);
        } catch (Error e) {
            if (stop_requested || panel_destroyed) {
                if (!panel_destroyed) {
                    GLib.Idle.add (() => { set_busy (false); return GLib.Source.REMOVE; });
                }
                return;
            }
            on_api_failed (e.message);
        }
    }

    // ─── 流式渲染 ────────────────────────────────────────────────────────

    private Gtk.Box? streaming_box = null;
    private Gtk.Label? streaming_label = null;

    private void begin_streaming () {
        end_streaming ();
        // 样式与 build_bubble 的 assistant 气泡一致; 内容用轻量 Label 增量更新,
        // 完成后由 rerender 重建为正式的 MarkdownView 气泡
        var bubble = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        bubble.add_css_class ("ai-bubble");
        bubble.add_css_class ("ai-bubble-assistant");
        bubble.hexpand = true;
        bubble.halign = Gtk.Align.FILL;
        var lbl = new Gtk.Label ("");
        lbl.xalign = 0;
        lbl.wrap = true;
        lbl.wrap_mode = Pango.WrapMode.WORD_CHAR;
        lbl.selectable = true;
        lbl.add_css_class ("ai-bubble-content");
        bubble.append (lbl);

        var outer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        outer.append (bubble);
        streaming_box = outer;
        streaming_label = lbl;
        chat_container.append (outer);
    }

    private void append_streaming_text (string piece) {
        if (streaming_box == null) begin_streaming ();
        if (streaming_label == null) return;
        streaming_label.label = streaming_label.label + sanitize_utf8 (piece);
        if (auto_scroll) scroll_to_bottom (false);
    }

    private void end_streaming () {
        if (streaming_box != null) {
            // rerender 重建后气泡已不在树上, 需检查 parent 避免 remove 警告
            if (streaming_box.get_parent () == chat_container) {
                chat_container.remove (streaming_box);
            }
            streaming_box = null;
            streaming_label = null;
        }
    }

    private async void on_api_finished (AIChatResult result) {
        // 网络响应目前在 worker 线程; 先通过 yield 切换到主线程,
        // 后续所有 GTK/状态操作都在主线程执行, 避免跨线程访问 GTK4 widget.
        if (!GLib.MainContext.default ().is_owner ()) {
            GLib.Idle.add (() => {
                on_api_finished.callback ();
                return GLib.Source.REMOVE;
            });
            yield;
        }
        // 窗口关闭后异步回调才切回主线程: widget 已销毁, 直接返回
        if (panel_destroyed || stop_requested) {
            if (!panel_destroyed) set_busy (false);
            return;
        }

        // 流式结束: 先移除临时流式气泡, 后续 render_assistant 重建正式气泡
        end_streaming ();

        // 数据: 构建 assistant 消息并写入历史
        var assistant_msg = new Json.Object ();
        assistant_msg.set_string_member ("role", "assistant");
        assistant_msg.set_string_member ("content", result.content ?? "");
        if (result.tool_calls.size > 0) {
            var arr = new Json.Array ();
            int idx = 0;
            foreach (var tc in result.tool_calls) {
                var tc_obj = new Json.Object ();
                tc_obj.set_string_member ("id", tc.id);
                tc_obj.set_string_member ("type", "function");
                var fn = new Json.Object ();
                fn.set_string_member ("name", tc.name);
                fn.set_string_member ("arguments", tc.arguments_json);
                tc_obj.set_member ("function", AI.SchemaHelper.obj_to_node (fn));
                tc_obj.set_int_member ("index", idx++);
                arr.add_object_element (tc_obj);
            }
            assistant_msg.set_member ("tool_calls", AI.SchemaHelper.arr_to_node (arr));
        }
        messages_lock.lock ();
        messages.add (AI.SchemaHelper.obj_to_node (assistant_msg));
        messages_lock.unlock ();

        if (result.content.length > 0) {
            render_assistant (result.content);
        }

        if (stop_requested) return;

        if (result.tool_calls.size > 0) {
            foreach (var tc in result.tool_calls) {
                if (stop_requested) break;
                string args_repr = AIPromptBuilder.format_tool_args (tc.name, tc.arguments_json);
                string result_str = yield execute_tool_async (tc.name, tc.arguments_json);
                if (stop_requested) break;
                render_tool (tc.name, args_repr, result_str);
                messages_lock.lock ();
                messages.add (build_tool_response (tc.id, result_str));
                messages_lock.unlock ();
            }
            if (!stop_requested) {
                next_turn ();
            } else {
                set_busy (false);
            }
        } else {
            // 没有后续工具调用 = agent 循环结束, 任务彻底完成
            task_completed (summarize_for_notification (result.content));
            set_busy (false);
        }
    }

    // 完成通知摘要: 取回复第一段非空文本, 折叠为单行并按字符数截断
    // (index_of_nth_char 按 UTF-8 字符定位, 不会切断多字节字符);
    // 全空回复返回空串, 由通知侧回退到通用文案
    private static string summarize_for_notification (string? content) {
        string text = content ?? "";
        foreach (string raw_line in text.split ("\n")) {
            string line = raw_line.strip ();
            if (line.length == 0) continue;
            long cut = line.index_of_nth_char (80);
            if (cut >= 0) {
                line = line.substring (0, cut) + "…";
            }
            return line;
        }
        return "";
    }

    // 异步工具执行: 若已在主线程则直接调用 tool_executor;
    // 否则通过 Idle 投递到主线程, yield 等待结果, 不阻塞 worker 线程.
    private async string execute_tool_async (string name, string args_json) {
        if (stop_requested || panel_destroyed) return "";
        if (GLib.MainContext.default ().is_owner ()) {
            try {
                if (tool_executor == null) return _("Tool executor not configured");
                return tool_executor (name, AIPromptBuilder.parse_args (args_json));
            } catch (Error e) {
                return _("Execution error: %s").printf (e.message);
            }
        }
        string result = "";
        GLib.Idle.add (() => {
            if (stop_requested || panel_destroyed) {
                result = "";
            } else {
                try {
                    if (tool_executor == null) {
                        result = _("Tool executor not configured");
                    } else {
                        result = tool_executor (name, AIPromptBuilder.parse_args (args_json));
                    }
                } catch (Error e) {
                    result = _("Execution error: %s").printf (e.message);
                }
            }
            execute_tool_async.callback ();
            return GLib.Source.REMOVE;
        });
        yield;
        return result;
    }

    private static Json.Node build_tool_response (string tool_call_id, string content) {
        var o = new Json.Object ();
        o.set_string_member ("role", "tool");
        o.set_string_member ("tool_call_id", tool_call_id);
        o.set_string_member ("content", content ?? "");
        return AI.SchemaHelper.obj_to_node (o);
    }

    private void on_api_failed (string err) {
        GLib.Idle.add (() => {
            if (panel_destroyed) return GLib.Source.REMOVE;
            set_busy (false);
            render_system (_("Call failed: %s").printf (err));
            return GLib.Source.REMOVE;
        });
    }


    // format_tool_args 已移至 services/ai_prompt_builder.vala (AIPromptBuilder 类).
    // 保留注释位置以维持代码结构清晰, 避免后续阅读时丢失上下文.


    // ─── 状态 ────────────────────────────────────────────────────────────

    private void set_busy (bool b) {
        // 状态未变化时跳过冗余的 UI 更新。
        // set_busy(false) 可从多个路径被调用 (on_api_finished / on_api_failed /
        // request_stop / run_worker 的 Idle 回调), 重复调用会触发不必要的 widget
        // 属性重置 (按钮文本/CSS 类/状态标签), 可能造成 UI 闪烁。
        if (busy == b) return;
        busy = b;
        if (b) {
            lbl_send.set_text (_("Stop"));
            send_icon.icon_name = "media-playback-stop-symbolic";
            btn_send.remove_css_class ("suggested-action");
            btn_send.add_css_class ("destructive-action");
            lbl_status.set_text (_("Thinking..."));
            status_spinner.visible = true;
            status_spinner.spinning = true;
        } else {
            lbl_send.set_text (_("Send"));
            send_icon.icon_name = "mail-send-symbolic";
            btn_send.remove_css_class ("destructive-action");
            btn_send.add_css_class ("suggested-action");
            update_status ();
            status_spinner.spinning = false;
            status_spinner.visible = false;
            end_streaming ();
        }
        // 输入框保持可编辑: 忙碌时允许用户预输入下一条消息 (主流聊天应用行为),
        // 发送按钮此时是 Stop, 不会误触发发送
        btn_clear.set_sensitive (!b);
    }

    private void update_status () {
        if (!ai_enabled) {
            lbl_status.set_text (_("Disabled"));
            lbl_status.remove_css_class ("ai-status-ok");
            lbl_status.add_css_class ("ai-status-warn");
        } else if (client == null) {
            lbl_status.set_text (_("Not configured"));
            lbl_status.remove_css_class ("ai-status-ok");
            lbl_status.add_css_class ("ai-status-warn");
        } else {
            lbl_status.set_text (_("Ready"));
            lbl_status.remove_css_class ("ai-status-warn");
            lbl_status.add_css_class ("ai-status-ok");
        }
    }
}
