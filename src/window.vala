using GLib;
using Gtk;
using Adw;
using Json;
using Gee;

[GtkTemplate (ui = "/io/github/sam_fic/filecollector/window.ui")]
public class FileCollectorWindow : Adw.ApplicationWindow {

    [GtkChild] private unowned Gtk.ScrolledWindow dir_scrolled;
    [GtkChild] private unowned Gtk.ListView queue_list;
    [GtkChild] private unowned Gtk.Overlay queue_overlay;
    [GtkChild] private unowned Gtk.Stack queue_stack;
    [GtkChild] private unowned Gtk.Box drop_indicator;
    [GtkChild] private unowned Gtk.Box left_panel_card;
    [GtkChild] private unowned Gtk.Box middle_panel_card;
    private Adw.StatusPage queue_empty_page;
    [GtkChild] private unowned Gtk.Stack preview_stack;
    [GtkChild] private unowned Gtk.Box preview_markdown_box;
    [GtkChild] private unowned Adw.StatusPage preview_info_box;
    [GtkChild] private unowned GtkSource.View preview_view;
    [GtkChild] private unowned Gtk.Button open_folder_btn;
    [GtkChild] private unowned Gtk.MenuButton menu_btn;
    [GtkChild] private unowned Gtk.Button btn_generate;
    [GtkChild] private unowned Gtk.Button btn_add_ext;
    [GtkChild] private unowned Gtk.Button btn_add_text_above;
    [GtkChild] private unowned Gtk.Button btn_add_text_below;
    [GtkChild] private unowned Gtk.Button btn_move_up;
    [GtkChild] private unowned Gtk.Button btn_move_down;
    [GtkChild] private unowned Gtk.Button btn_delete;
    [GtkChild] private unowned Gtk.Button btn_clear;
    [GtkChild] private unowned Gtk.CheckButton radio_relative_path;
    [GtkChild] private unowned Gtk.CheckButton radio_absolute_path;
    [GtkChild] private unowned Gtk.CheckButton check_write_header;
    [GtkChild] private unowned Gtk.Button btn_ai_toc;
    [GtkChild] private unowned Gtk.SearchEntry search_entry;
    [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
    [GtkChild] private unowned Gtk.Paned outer_paned;
    [GtkChild] private unowned Gtk.Paned inner_paned;
    [GtkChild] private unowned Gtk.ToggleButton btn_ai_toggle;
    [GtkChild] private unowned Gtk.ToggleButton btn_toggle_snapshot;

    // 工作区快照栏 (在 Vala 中构建, 因 blueprint 0.19 无法正确为
    // AdwOverlaySplitView 指定 sidebar/content 子控件, 导致侧栏空白)
    [GtkChild] private unowned Adw.ToolbarView main_view;
    private Adw.OverlaySplitView snapshot_split;
    private Adw.Sidebar snapshot_sidebar;
    private Gtk.Button btn_new_snapshot;

    // AI 右侧栏 (同样原因在 Vala 中构建, 见 build_ai_split_view)
    private Adw.OverlaySplitView ai_split;
    private Gtk.Box ai_sidebar;
    // main_view 外的 Gtk.Overlay (VLM 进度卡片悬浮层), 也是 ai_split 的 content
    private Gtk.Overlay main_overlay;

    [GtkChild] private unowned Gtk.Button btn_retry_preprocess;
    [GtkChild] private unowned Gtk.Button btn_export_cache;
    [GtkChild] private unowned Gtk.Box preview_action_buttons;
    [GtkChild] private unowned Gtk.DrawingArea token_ring;
    [GtkChild] private unowned Gtk.ScrolledWindow preview_scrolled;

    // Git 模式切换
    [GtkChild] private unowned Gtk.Button btn_toggle_git;
    [GtkChild] private unowned Gtk.Label lbl_left_title;
    [GtkChild] private unowned Gtk.Button btn_global_search;
    [GtkChild] private unowned Gtk.Stack left_stack;
    [GtkChild] private unowned Gtk.Stack action_stack;
    [GtkChild] private unowned Gtk.Box tree_page;
    [GtkChild] private unowned Gtk.Box git_page;
    [GtkChild] private unowned Gtk.Box normal_actions;
    [GtkChild] private unowned Gtk.Box git_actions;
    [GtkChild] private unowned Gtk.ListView git_list_view;
    [GtkChild] private unowned Gtk.ScrolledWindow git_scrolled;
    [GtkChild] private unowned Gtk.SearchEntry git_search_entry;
    [GtkChild] private unowned Gtk.Button btn_git_add_all_changed;
    [GtkChild] private unowned Gtk.Button btn_git_export_working_diff;
    [GtkChild] private unowned Gtk.Button btn_git_export_commit_diff;
    [GtkChild] private unowned Gtk.Button btn_git_delete;
    [GtkChild] private unowned Gtk.Button btn_git_clear;

    private Gtk.ColumnView dir_column_view;
    private Gtk.TreeListModel tree_list_model;
    private Gtk.FilterListModel filter_model;
    private Gtk.CustomFilter tree_filter;
    private Gtk.SingleSelection tree_selection;
    private GLib.ListStore root_store;
    private string search_text = "";
    // 搜索匹配缓存: 存放"自身或其子树存在名称匹配"的节点 path。
    // 预计算一次, filter_tree_func 直接查表, 避免每个可见节点都递归遍历子树。
    private Gee.HashSet<string> matching_paths = new Gee.HashSet<string> ();

    private GLib.ListStore queue_store;

    // 快照栏: AdwSidebarItem 列表 (与 app_state.snapshots 一一对应)
    private GLib.ListStore snapshot_store;
    private Adw.SidebarSection snapshot_section;
    private int snapshot_selected_index = -1;
    // 删除工作区动作, 提升为字段以便在 snapshots 数量变化时动态启用/禁用.
    private GLib.SimpleAction delete_snapshot_act;
    // 当前激活的工作区索引: 正在编辑的内容始终属于该 Workspace,
    // 打开目录 / 切换 / 新建前都会把当前状态同步回它, 避免内容游离在列表之外.
    private int active_workspace_index = -1;
    private Gtk.MultiSelection queue_selection;

    // 防御: 在对 queue_store/queue_selection 进行突变 (splice/unselect/select)
    // 时增加深度计数, 防止 selection_changed / notify 等信号处理函数重入访问
    // 模型, 避免 gtk_selection_model_get_selection 断言失败或空指针解引用崩溃.
    private int queue_update_depth = 0;

    private AppState app_state;
    // 向后兼容访问器, 逐步迁移到直接通过 app_state 访问
    private Gee.ArrayList<ItemData> items { get { return app_state.items; } }
    private CheckStateModel check_model { get { return app_state.check_model; } }
    private Gee.ArrayList<string> common_phrases { get { return app_state.common_phrases; } }
    private File? work_dir {
        get { return app_state.work_dir; }
        set {
            app_state.work_dir = value;
            // 打开/更改工作目录时, 把当前状态同步回激活的工作区,
            // 使该目录归属于当前 Workspace (而非游离).
            sync_active_snapshot ();
            update_empty_state ();
        }
    }
    private bool use_absolute { get { return app_state.use_absolute; } set { app_state.use_absolute = value; } }
    private bool show_header { get { return app_state.show_header; } set { app_state.show_header = value; } }
    private string? project_file { get { return app_state.project_file; } set { app_state.project_file = value; } }
    private string ai_mode { get { return app_state.ai_mode; } set { app_state.ai_mode = value; } }
    private string ai_file_extension { get { return app_state.ai_file_extension; } set { app_state.ai_file_extension = value; } }
    private string ai_file_label { get { return app_state.ai_file_label; } set { app_state.ai_file_label = value; } }
    private int ai_max_files { get { return app_state.ai_max_files; } set { app_state.ai_max_files = value; } }

    private UndoManager undo_manager;
    private ProjectController project_controller;
    private AIController ai_controller;

    private Adw.WindowTitle? _title_widget;

    private PhrasesPicker? phrases_picker_instance = null;

    // AI 助手
    private AIPanel? ai_panel_instance = null;
    private PreferencesDialog? preferences_dialog_instance = null;
    private bool ai_panel_visible = false;

    // 操作令牌: 目录勾选等分批任务递增, 旧令牌任务在 Idle 中自行放弃, 防止上下文切换后仍修改旧列表
    private uint current_operation_token = 0;
    // 每个目录各自的最新令牌, 仅当同一目录有更新的操作时才放弃旧的 items 分批任务, 避免不同目录间的误取消
    private Gee.HashMap<string, uint> dir_operation_tokens = new Gee.HashMap<string, uint> ();
    private uint ensure_path_token = 0;

    // Git 模式状态
    private bool is_git_mode = false;
    private ulong handler_path_abs;
    private ulong handler_path_rel;
    private ulong handler_header;

    // 空状态引导 (非 Git 模式)
    private Adw.StatusPage empty_page_widget;
    private Gtk.Widget? saved_toolbar_content = null;

    // 目录加载进度条
    private Gtk.Revealer dir_load_revealer;
    private Gtk.ProgressBar dir_load_progress;
    private Gtk.Label dir_load_label;

    private GitHistoryPanel git_panel;
    private RecoveryManager recovery_manager;

    // VLM 预处理队列控制器: 封装 VLMQueueManager/VLMTaskRunner + 悬浮进度卡片.
    // 字段持有理由: 必须跨 setup_vlm_queue 生命周期存活 (vlm_queue.executor 是
    // unowned 委托, Controller 必须长寿); on_close_request 也要通过它取消并等待
    // 工作线程退出.
    private VlmQueueController? vlm_controller;

    // Token 估算
    private int current_context_limit = 128000;
    private double current_token_ratio = 0.0;

    private ItemData? current_preview_item = null;

    // ─── 预览懒加载状态 ────────────────────────────────────────────────
    private string? preview_current_path = null;
    private int64 preview_file_size = 0;
    private int64 preview_loaded_bytes = 0;
    private uint8[] preview_leftover = new uint8[0];
    private bool preview_fully_loaded = false;
    private bool preview_loading = false;
    private InputStream? preview_fis = null;
    private bool preview_auto_scroll = true;
    // 当前正在拖拽的源项: drag.prepare 时记录, drag_end 时清空.
    // 用于在 drop.motion 中跳过"悬停在源项自身"的落点指示线 (插到自身前/后等于没移动).
    private ItemData? dragging_item = null;
    private const int64 PREVIEW_CHUNK_SIZE = 262144; // 256KB: 大文件分块读取的块大小 (原 64KB 会导致过多线程往返)

    // 预览代际令牌: 每次发起新的懒加载预览 (start_lazy_preview) 或取消加载
    // (cancel_preview_loading) 时自增. 每个 load_preview_chunk 后台线程在生成时捕获
    // 当前代际, 只有当捕获值与当前 preview_generation 一致时才允许把读到的内容写入
    // 缓冲区. 这样即便一次移动/重选触发了多个并行的预览线程 (它们各自以偏移 0 重读整
    // 个文件), 也只有最后一次请求的数据会被真正追加, 从而避免预览内容重复显示.
    private uint preview_generation = 0;
    // 上次发起预览的时间戳 (毫秒), 用于合并快速重入的重复预览请求
    // (例如一次拖拽/添加操作会经 items_changed -> refresh_list -> on_queue_selection_changed
    // 多次触发 update_preview, 去抖可避免对同一个文件重复读取/重建).
    private int64 preview_last_request_ms = 0;
    // 记录上次因列表选择变化而预览的选中项集合, refresh_list 末尾据此判断选择是否真的
    // 变了, 没变则跳过再次 update_preview, 避免无谓的重载与闪烁.
    private Gee.ArrayList<int>? last_previewed_selection = null;
    // Markdown 预览构建结果缓存: 重复点击同一文件 (mtime 不变) 直接复用已构建的
    // widget 树, 避免每次切换都重新解析 AST + 重建全部子 widget (长文档耗时显著).
    private MarkdownView? markdown_cache_view = null;
    private string? markdown_cache_key = null;
    // 大 Markdown 文档 (>200KB) 的构建放到空闲回调中执行, 先显示占位, 避免阻塞切换.
    private const int64 MARKDOWN_DEFER_THRESHOLD = 200 * 1024;


    public FileCollectorWindow (Adw.Application app) {
        GLib.Object (application: app);
    }

    construct {
        app_state = new AppState ();
        project_controller = new ProjectController (app_state);
        ai_controller = new AIController (app_state);
        undo_manager = new UndoManager ();
        recovery_manager = new RecoveryManager (app_state);

        ConfigManager.load_common_phrases (app_state.common_phrases);
        load_css ();

        bind_app_state_signals ();

        setup_queue_list ();
        setup_tree_view ();
        init_git_panel ();
        setup_snapshot_sidebar ();
        setup_vlm_queue ();
        // 须晚于 setup_vlm_queue (依赖其创建的 main_overlay 层级),
        // 早于 setup_ai_panel (按钮绑定需要 ai_split 已存在)
        build_ai_split_view ();
        setup_preview_syntax ();
        setup_preview_signals ();
        sync_path_mode_radios ();
        setup_signals ();
        setup_ai_panel ();
        setup_shortcuts ();
        setup_empty_state ();
        search_entry.visible = false;

        // 窗口级 width-request 兜底最小宽须在首次呈现前建立 (详见该方法注释):
        // 断点容器把内容申报的最小宽归零后, 这是三卡片不被拖窗口边缘裁切的唯一硬下限.
        // 关键: blp 里写的 shrink-*-child: false 在运行时不生效 —— 实测
        // outer_paned.measure() 只申报出 48 (= 自身左右边距 36 + 一个把手 12),
        // 即两个子项都按 "可缩到 0" 计; 同时拖分隔条可把左栏压到 31px 而不停手.
        // GtkPaned 的最小宽申报与位置钳位都以这两个 flag 为准, 一旦为 true,
        // 窗口硬下限和分隔条约束会同时失效. 故程序化强制设置, 不依赖 BLP 编译
        // (与历史上 PaneLayoutManager 的结论一致).
        outer_paned.shrink_start_child = false;
        outer_paned.shrink_end_child = false;
        inner_paned.shrink_start_child = false;
        inner_paned.shrink_end_child = false;

        establish_width_floor ();

        // 拖分隔条时的数值留痕 (仅在 FILECOLLECTOR_LAYOUT_DEBUG=1 下输出)
        outer_paned.notify["position"].connect (() => dump_layout ("drag"));
        inner_paned.notify["position"].connect (() => dump_layout ("drag"));

        current_context_limit = ConfigManager.get_context_window_size ();

        token_ring.set_draw_func ((area, cr, width, height) => {
            double cx = width / 2.0;
            double cy = height / 2.0;
            double radius = (width / 2.0) - 2.0;
            double line_width = 2.5;

            cr.set_source_rgba (1.0, 1.0, 1.0, 0.25);
            cr.set_line_width (line_width);
            cr.arc (cx, cy, radius, 0, 2 * Math.PI);
            cr.stroke ();

            if (current_token_ratio > 0) {
                if (current_token_ratio >= 0.9) {
                    cr.set_source_rgba (0.88, 0.11, 0.14, 1.0);
                } else if (current_token_ratio >= 0.7) {
                    cr.set_source_rgba (0.90, 0.65, 0.04, 1.0);
                } else {
                    cr.set_source_rgba (0.22, 0.52, 0.18, 1.0);
                }

                cr.set_line_width (line_width);
                double end_angle = -Math.PI / 2 + (2 * Math.PI * current_token_ratio.clamp (0.0, 1.0));
                cr.arc (cx, cy, radius, -Math.PI / 2, end_angle);
                cr.stroke ();
            }
        });

        btn_retry_preprocess.clicked.connect (() => {
            var indices = get_selected_indices ();
            if (indices.size == 1) {
                int sel = indices.get (0);
                if (sel >= 0 && sel < items.size) {
                    on_retry_preprocess (items.get (sel));
                }
            }
        });

        btn_export_cache.clicked.connect (() => {
            if (current_preview_item != null) {
                export_item_cache (current_preview_item);
            }
        });

        this.close_request.connect (on_close_request);

        // 窗口被加入 Application 后 application 属性才非空,
        // 此时需要重新同步一次依赖 application 的菜单 Action 状态.
        this.notify["application"].connect (() => {
            update_workdir_dependent_buttons ();
            update_queue_buttons ();
        });

        GLib.Idle.add (() => {
            cache_title_widget ();
            recovery_manager.maybe_prompt_restore (this, app_state.project_file);
            return Source.REMOVE;
        });
    }

    private void bind_app_state_signals () {
        app_state.items_changed.connect (refresh_list);
        app_state.items_changed.connect (() => recovery_manager.schedule ());
        app_state.state_changed.connect (() => {
            sync_path_mode_radios ();
            sync_header_checkbox ();
            update_title ();
            update_action_sensitivity ();
            update_workdir_dependent_buttons ();
            recovery_manager.schedule ();
        });

        recovery_manager.restored.connect (on_recovery_restored);
        recovery_manager.restore_failed.connect ((msg) => {
            toast_overlay.add_toast (new Adw.Toast (_("Restore failed: ") + msg));
        });

        // AIController 信号 → View 层 UI 操作
        ai_controller.undo_snapshot_requested.connect (() => push_undo_state ());
        ai_controller.undo_delta_requested.connect ((delta) => push_undo_delta (delta));
        ai_controller.tree_check_changed.connect ((path, checked) => set_tree_item_check (path, checked));
        ai_controller.work_dir_change_requested.connect ((path) => ai_apply_set_work_dir (path));
        ai_controller.clear_items_requested.connect (() => on_clear_items ());
        ai_controller.refresh_list_requested.connect (() => refresh_list ());
        // AI 侧边栏添文件后, 主动触发对应 item 的二进制预处理
        ai_controller.preprocess_item_requested.connect ((path) => {
            for (int i = 0; i < items.size; i++) {
                var it = items.get (i);
                if (it.item_type == "file" && it.file_path == path) {
                    if (it.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        enqueue_item_for_preprocess (it);
                    }
                    break;
                }
            }
        });
        ai_controller.ai_batch_operation_completed.connect (on_ai_batch_operation_completed);
    }

    private void on_ai_batch_operation_completed (string summary) {
        if (!undo_manager.can_undo) return;

        var toast = new Adw.Toast (summary);
        toast.set_button_label (_("Undo"));
        toast.set_timeout (6);

        toast.button_clicked.connect (() => {
            on_undo ();
            var confirm = new Adw.Toast (_("AI operation undone"));
            confirm.set_timeout (2);
            toast_overlay.add_toast (confirm);
        });

        toast_overlay.add_toast (toast);
    }

    private bool on_close_request () {
        if (app_state.app_cancellable != null) {
            app_state.app_cancellable.cancel ();
        }
        cancel_preview_loading ();
        if (vlm_controller != null) {
            // 阻塞等待活动 VLM 任务退出 (带超时), 避免主程序退出后
            // 工作线程仍访问已释放的 BinaryConverter.temp_base_dir
            vlm_controller.cancel_and_wait ();
        }
        if (ai_panel_instance != null) {
            ai_panel_instance.shutdown ();
        }
        // 先取消挂起的自动保存定时器, 再同步保存一次
        // (保证 5s 延迟窗口内的状态变更也能落盘, 避免点关闭瞬间数据丢失)
        recovery_manager.cancel ();
        recovery_manager.save ();
        app_state.window_closing = true; // 必须在 save 之后置位, 否则 save 第一行会因 app_state.window_closing 早退

        // 编排列表非空 → 弹确认对话框, 避免用户误关丢失未保存内容
        if (items.size > 0) {
            var dialog = new Adw.AlertDialog (
                _("Confirm Close"),
                _("There is unsaved content in the current orchestration list.\nAfter closing, recovery will not be prompted on next launch. Close anyway?")
            );
            dialog.add_response ("cancel", _("Cancel"));
            dialog.add_response ("close", _("Close"));
            dialog.set_response_appearance ("close", Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_default_response ("cancel");
            dialog.set_close_response ("cancel");
            dialog.response.connect ((response) => {
                dialog.destroy ();
                if (response == "close") {
                    // 用户明确确认关闭 → 删除恢复文件, 下次启动不再弹恢复提示
                    recovery_manager.delete_file ();
                    // destroy() 不会再次触发 close-request, 不会递归进 on_close_request
                    this.destroy ();
                }
                // "cancel" / Esc: 恢复文件保留, 窗口保持打开 (GTK4 看到 on_close_request 返回 true 已阻止销毁)
            });
            dialog.present (this);
            return true; // 阻止窗口关闭, 等待用户在对话框中确认
        }

        // 编排列表为空: recovery_manager.save() 内部已经自动删除恢复文件, 直接放行
        app_state.bg_threads.clear ();
        return false;
    }

    // ─── 自动保存 / 崩溃恢复 (逻辑在 RecoveryManager) ──────────────────────

    // RecoveryManager 还原成功后的 UI 刷新: 逻辑原在 check_recovery_on_startup 的
    // restore 分支, 因涉及窗口控件 (root_store / search_entry / toast_overlay) 留在窗口.
    private void on_recovery_restored (File? wd) {
        undo_manager.clear ();
        // 复原工作区文件夹位置: 重建目录树、加载子项、展开根节点
        if (wd != null) {
            if (wd.query_exists ()) {
                update_ui_after_project_load ();
            } else {
                // 文件夹已被删除/移动: 保留工作目录元数据但清空目录树
                update_subtitle (wd.get_path () + "  (" + _("Folder does not exist") + ")");
                root_store.remove_all ();
                search_entry.visible = false;
                refresh_list ();
                update_action_sensitivity ();
                update_workdir_dependent_buttons ();
            }
        } else {
            update_title ();
            refresh_list ();
            update_workdir_dependent_buttons ();
        }
        toast_overlay.add_toast (new Adw.Toast (_("Session restored successfully")));
    }

    private void load_css () {
        var provider = new Gtk.CssProvider ();
        try {
            provider.load_from_resource ("/io/github/sam_fic/filecollector/style.css");
            Gtk.StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        } catch (Error e) {
            warning ("Failed to load CSS: %s", e.message);
        }
    }

    public static string load_settings_language () {
        return ConfigManager.load_settings_language ();
    }

    private void setup_queue_list () {
        queue_store = new GLib.ListStore (typeof (ItemData));
        queue_selection = new Gtk.MultiSelection (queue_store);

        // 行构建/绑定/解绑逻辑抽到 QueueListFactory, 通过 Hooks 委托回 Window
        // 访问私有状态 (dragging_item, queue_update_depth, current_preview_item).
        var factory = QueueListFactory.create (
            () => queue_update_depth > 0,
            () => dragging_item,
            (item) => dragging_item = item,
            QueueListFactory.render_row_default,
            show_queue_context_menu,
            update_preview,
            refresh_preview_if_active,
            clear_tree_selection,
            set_drop_indicator
        );

        queue_list.model = queue_selection;
        queue_list.factory = factory;

        // 统一 DropTarget 挂在 queue_list 上: 覆盖整个列表区域, 无盲区.
        // 之前的方案在每行 box 上各挂一个 DropTarget, 行间缝隙 (CSS 间距/回收重用)
        // 会导致 DropTarget 事件丢失或落点错误. 统一 DropTarget 用 pick() 定位目标行.
        var list_drop = new Gtk.DropTarget (typeof (ItemData), Gdk.DragAction.MOVE);
        list_drop.motion.connect ((s, x, y) => {
            var target_box = pick_row_box (x, y);
            if (target_box == null) {
                set_drop_indicator (null, false);
            } else {
                var target_data = target_box.get_data<ItemData> ("queue-item");
                double rel_x, rel_y;
                bool have_rel = queue_list.translate_coordinates (target_box, x, y, out rel_x, out rel_y);
                bool drop_after = have_rel && rel_y > target_box.get_height () / 2;
                bool skip = false;
                if (target_data != null && dragging_item != null) {
                    int from = find_item_index (dragging_item);
                    int t = find_item_index (target_data);
                    if (from >= 0 && t >= 0) {
                        // 插入位置 k: 落在 t 的上半区 = 插到 t 前(k=t), 下半区 = 插到 t 后(k=t+1)
                        // 当 k == from 或 k == from+1 时, 等价于"插到源项自身的前/后"=没移动, 不显示指示线
                        int k = drop_after ? t + 1 : t;
                        if (k == from || k == from + 1) skip = true;
                    }
                }
                if (skip) {
                    set_drop_indicator (null, false);
                } else {
                    set_drop_indicator (target_box.get_parent (), drop_after);
                }
            }
            return Gdk.DragAction.MOVE;
        });
        list_drop.drop.connect ((s, val, x, y) => {
            var dragged = val.get_object () as ItemData;
            if (dragged == null) return false;
            set_drop_indicator (null, false);

            var target_box = pick_row_box (x, y);
            if (target_box == null) {
                // 列表末行以下的空白区: 移到末尾
                reorder_queue_item (dragged, (int) queue_store.get_n_items () - 1, true);
                return true;
            }

            var target_data = target_box.get_data<ItemData> ("queue-item");
            if (target_data == null) return true;

            double rel_x, rel_y;
            bool have_rel = queue_list.translate_coordinates (target_box, x, y, out rel_x, out rel_y);
            bool drop_after = have_rel && rel_y > target_box.get_height () / 2;

            // 与 motion 一致的抑制逻辑: 插入位置 k == from 或 from+1 时为"原地移动", 忽略
            if (dragging_item != null) {
                int from = find_item_index (dragging_item);
                int t = find_item_index (target_data);
                if (from >= 0 && t >= 0) {
                    int k = drop_after ? t + 1 : t;
                    if (k == from || k == from + 1) return true;
                }
            }

            int target_row = find_item_index (target_data);
            if (target_row < 0) return true;

            reorder_queue_item (dragged, target_row, drop_after);
            return true;
        });
        queue_list.add_controller (list_drop);

        // 外部拖拽 (Nautilus / 文件管理器): 第二个 DropTarget, 仅接收 Gdk.FileList,
        // 与上面的内部重排 DropTarget(ItemData) 类型互斥, GTK 自动按 source 内容路由,
        // 不会干扰现有手柄拖拽排序.
        setup_external_drop_on_queue ();

        // 指示线覆盖层不拦截指针事件, 否则会挡在行上方吞掉该 2px 区域的拖拽/落点
        drop_indicator.can_target = false;

        // 编排列表空状态: StatusPage 作为 queue_stack 的第二页, 由 refresh_list
        // 根据 items 数量在列表页/空状态页间切换. 图标 + 标题 + 描述, 风格与预览区统一.
        queue_empty_page = new Adw.StatusPage ();
        queue_empty_page.icon_name = "list-add-symbolic";
        queue_empty_page.title = _("No files collected yet");
        queue_empty_page.description = _("Check files in the directory tree or add custom text to build your collection.");
        queue_stack.add_child (queue_empty_page);
    }

    // 右键菜单弹出前同步选中状态: 多选场景下右键未选中项时, 把选中集合收敛为该项,
    // 让 get_selected_indices() 在菜单回调时返回正确集合. 由 QueueListFactory
    // 通过 ShowContextMenu Hook 调用 (factory 不持有 Gtk.SelectionModel 引用).
    private void show_queue_context_menu (Gtk.Widget parent, ItemData item, int index, int gx, int gy) {
        // 关键修复: gtk_selection_model_get_selection 返回 transfer-none 的 bitset,
        // Vala VAPI 错误地将其标为 transfer-full, 导致 Vala 生成 gtk_bitset_unref,
        // 进而释放 selection model 内部持有的 bitset, 破坏模型状态并引发崩溃.
        // 改用 is_selected() 完全避免 get_selection() 调用.
        if (!queue_selection.is_selected ((uint) index)) {
            queue_selection.unselect_all ();
            queue_selection.select_item ((uint) index, false);
        }
        ctx_item = item;
        ctx_index = index;
        var indices = get_selected_indices ();
        bool can_export = can_export_item_cache (item);
        ContextMenus.show_queue_menu (
            parent, item, gx, gy,
            indices, items, work_dir, use_absolute,
            on_ctx_edit_text,
            on_ctx_refresh_list,
            on_ctx_push_undo,
            on_ctx_retry_preprocess,
            on_ctx_copy_path,
            on_ctx_show_folder,
            () => on_ctx_export_cache (item),
            can_export
        );
    }

    // VLM 预处理状态变化时, 若本行是被选中的当前预览项则刷新预览.
    // 由 QueueListFactory 通过 RefreshPreviewIfActive Hook 调用.
    // 防御 queue_update_depth > 0 时跳过: 避免在模型突变时访问 queue_selection
    // 触发 GTK 断言失败.
    private void refresh_preview_if_active (ItemData data, uint position) {
        if (queue_update_depth > 0) return;
        if (position < queue_store.get_n_items ()
            && queue_selection.is_selected (position)
            && queue_store.get_item (position) == data
            && data == current_preview_item) {
            // 仅当该项确为当前预览项时才刷新: 状态变化 (如 VLM 完成) 通常只影响
            // 预览内容, 且 update_preview 内部已对 80ms 内的重复请求去抖, 这里
            // 再限定"是当前预览项"可避免对后台非可见文件做无用读取.
            update_preview (data);
        }
    }

    private void setup_tree_view () {
        // factory 三回调 + 数据模型链 (root_store → TreeListModel → FilterListModel
        // → SingleSelection) 抽到 FileTreeFactory, 通过 Hooks 委托回 Window.
        var result = FileTreeFactory.create (
            filter_tree_func,
            on_tree_selection_changed,
            on_column_view_activated,
            preview_tree_item_at,
            () => queue_selection.unselect_all (),
            show_tree_context_menu,
            on_check_toggled,
            highlight_tree_label,
            load_directory_children_lazy
        );

        root_store = result.root_store;
        tree_list_model = result.tree_list_model;
        tree_filter = result.tree_filter;
        filter_model = result.filter_model;
        tree_selection = result.tree_selection;
        dir_column_view = result.view;

        // dir_scrolled 是 [GtkChild] 模板绑定, factory 不应接触, 故挂载留在这里.
        dir_scrolled.set_child (dir_column_view);

        // 外部拖拽到目录树: 拖文件夹 → 切换工作目录; 拖文件 → 作为外部文件加入编排列表.
        setup_external_drop_on_tree ();
    }

    // ─── 外部拖拽 (Nautilus / 系统文件管理器) ────────────────────────────────

    // 编排列表接收外部文件 / 文件夹: 文件→入列; 文件夹→递归收集其中所有文件入列.
    // 与内部 ItemData 重排 DropTarget 共存, 通过 content type 路由互不干扰.
    // 外部拖拽悬停高亮: 拖拽进入/离开目标区域时给该区域的卡片面板增删
    // .drop-target-active 类, 由 CSS 呈现为圆角 accent 描边 + 淡背景, 作为
    // "松手即可放入" 的原生提示. 高亮作用在整个卡片面板 (而非内部 widget),
    // 框线与卡片轮廓一致, 不与内部内容贴边, 与面板边距统一.
    private void set_external_drop_highlight (Gtk.Widget target, bool active) {
        if (target == null) return;
        if (active) {
            target.add_css_class ("drop-target-active");
        } else {
            target.remove_css_class ("drop-target-active");
        }
    }

    private void setup_external_drop_on_queue () {
        // 挂在 middle_panel_card (整个中栏卡片, 含标题/列表/按钮区), 使栏内所有
        // 区域(不仅限于列表内容区)都能接收拖拽, 与 .drop-target-active 高亮覆盖
        // 整栏的视觉一致. 子 widget(按钮/列表行)无 FileList 类型 DropTarget,
        // 拖拽文件时事件自然冒泡到本卡片的 DropTarget.
        var ext_drop = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        ext_drop.enter.connect (() => { set_external_drop_highlight (middle_panel_card, true); return Gdk.DragAction.COPY; });
        ext_drop.leave.connect (() => { set_external_drop_highlight (middle_panel_card, false); });
        ext_drop.drop.connect (on_external_drop_on_queue);
        middle_panel_card.add_controller (ext_drop);
    }

    private bool on_external_drop_on_queue (GLib.Value val, double x, double y) {
        var file_list = val as Gdk.FileList;
        if (file_list == null) return false;
        var to_add = new Gee.ArrayList<ItemData> ();
        int skipped = 0;
        foreach (unowned var f in file_list.get_files ()) {
            string? path = f.get_path ();
            if (path == null) continue;
            add_external_path_to_batch (path, to_add, ref skipped);
        }
        int added = commit_external_batch (to_add);
        if (added > 0) {
            show_toast (_("Dropped %d file(s), skipped %d duplicate(s)").printf (added, skipped));
        } else if (skipped > 0) {
            show_toast (_("All %d file(s) already in list").printf (skipped));
        }
        return true;
    }

    // 目录树接收外部文件夹: 单一文件夹 → 切换工作目录; 其它(文件 / 多文件夹) →
    // 作为外部文件加入编排列表, 复用 add_external_path_to_batch 的递归收集逻辑.
    private void setup_external_drop_on_tree () {
        // 挂在 left_panel_card (整个左栏卡片, 含标题/搜索框/树区), 使栏内所有区域
        // 都能接收拖拽, 与 .drop-target-active 高亮覆盖整栏的视觉一致. ColumnView 是
        // 复合 widget, 拖拽 hover 的 enter 事件不稳定, 挂在卡片上更可靠.
        var ext_drop = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        ext_drop.enter.connect (() => { set_external_drop_highlight (left_panel_card, true); return Gdk.DragAction.COPY; });
        ext_drop.leave.connect (() => { set_external_drop_highlight (left_panel_card, false); });
        ext_drop.drop.connect (on_external_drop_on_tree);
        left_panel_card.add_controller (ext_drop);
    }

    // 目录树栏接收外部拖拽的语义是"切换工作目录", 而非加入编排列表:
    // 拖入文件夹 → 以其自身为工作目录; 拖入文件 → 以其父目录为工作目录.
    // 多个条目时优先取第一个文件夹, 否则用第一个文件的父目录.
    private bool on_external_drop_on_tree (GLib.Value val, double x, double y) {
        var file_list = val as Gdk.FileList;
        if (file_list == null) return false;
        var files = file_list.get_files ();
        if (files.length () == 0) return false;

        // 优先取列表中的第一个文件夹作为工作目录
        File? target_dir = null;
        foreach (unowned var f in files) {
            string? p = f.get_path ();
            if (p != null && FileUtils.test (p, FileTest.IS_DIR)) {
                target_dir = f;
                break;
            }
        }
        // 没有文件夹(全是文件): 取第一个文件的父目录作为工作目录
        if (target_dir == null) {
            var parent = files.data.get_parent ();
            if (parent != null) target_dir = parent;
        }
        if (target_dir == null) return false;

        string? work_dir_path = target_dir.get_path ();
        if (work_dir_path == null) return false;
        ai_apply_set_work_dir (work_dir_path);
        show_toast (_("Working directory: %s").printf (work_dir_path));
        return true;
    }

    // 首次打开 (未设工作目录) 时, 主内容区显示 empty_page_widget. 拖入任意文件/
    // 文件夹即设为工作目录: 文件夹直接取自身, 文件取所在父目录. 与打开文件夹按钮 /
    // 拖目录树单一文件夹行为一致 (复用 ai_apply_set_work_dir, 会清空编排列表并加载树).
    private bool on_external_drop_on_empty_state (GLib.Value val, double x, double y) {
        var file_list = val as Gdk.FileList;
        if (file_list == null) return false;
        var files = file_list.get_files ();
        if (files.length () == 0) return false;

        unowned var first = files.data;
        string? path = first.get_path ();
        if (path == null) return false;

        string work_dir_path;
        if (FileUtils.test (path, FileTest.IS_DIR)) {
            work_dir_path = path;
        } else {
            // 拖入的是文件: 以其所在父目录作为工作目录
            var parent = first.get_parent ();
            string? parent_path = parent != null ? parent.get_path () : null;
            if (parent_path == null) return false;
            work_dir_path = parent_path;
        }

        ai_apply_set_work_dir (work_dir_path);
        show_toast (_("Working directory: %s").printf (work_dir_path));
        return true;
    }

    private void on_column_view_activated (uint position) {
        preview_tree_item_at (position);
        queue_selection.unselect_all ();
    }

    private void on_tree_selection_changed (uint position, uint n_items) {
        if (position == Gtk.INVALID_LIST_POSITION) return;
        preview_tree_item_at (position);
        queue_selection.unselect_all ();
    }

    private void preview_tree_item_at (uint position) {
        var row = filter_model.get_item (position) as Gtk.TreeListRow;
        if (row == null) return;

        var item = row.get_item () as DirectoryItem;
        if (item == null || item.is_dir) return;

        var temp_item = new ItemData ("file", item.path, null, false);

        // 二进制文件仅检查缓存, 命中则直接展示; 未命中不触发 VLM 转换
        if (temp_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            // work_dir 可能为非空但失效的 GFile (例如跨线程引用计数竞争后释放),
            // get_path() 此时返回 null 并触发 G_IS_FILE 临界警告. 这里提前取路径并判空,
            // 避免将 null 传给 PreprocessCache 构造函数导致后续解引用崩溃.
            string? work_dir_path = (work_dir != null) ? work_dir.get_path () : null;
            if (work_dir_path != null) {
                try {
                    string? cached = BinaryPreprocessor.try_cache_only (temp_item, work_dir_path);
                    if (cached != null) {
                        temp_item.preprocess_status = PreprocessStatus.COMPLETED;
                        temp_item.preprocessed_content = cached;
                        temp_item.from_cache = true;
                    }
                } catch (Error e) {
                    // 缓存检查失败, 保持 NONE 状态, 展示"预览不可用"
                }
            }
        }

        update_preview (temp_item);
    }

    private void clear_tree_selection () {
        tree_selection.selected = Gtk.INVALID_LIST_POSITION;
    }

    private void on_search_changed () {
        search_text = search_entry.text;
        rebuild_matching_cache ();
        tree_filter.changed (Gtk.FilterChange.DIFFERENT);
    }

    private void highlight_tree_label (Gtk.Label label, string name) {
        if (search_text.length == 0) {
            label.set_text (name);
            return;
        }
        string lower_name = name.casefold ();
        string lower_search = search_text.casefold ();
        int idx = lower_name.index_of (lower_search);
        if (idx < 0) {
            label.set_text (name);
            return;
        }
        string escaped = GLib.Markup.escape_text (name);
        string escaped_search = GLib.Markup.escape_text (name.substring (idx, search_text.length));
        // 重新搜索转义后的文本 (因为 escape 可能改变长度)
        string lower_escaped = escaped.casefold ();
        string lower_escaped_search = escaped_search.casefold ();
        int esc_idx = lower_escaped.index_of (lower_escaped_search);
        if (esc_idx < 0) {
            label.set_markup (escaped);
            return;
        }
        string before = escaped.substring (0, esc_idx);
        string match = escaped.substring (esc_idx, escaped_search.length);
        string after = escaped.substring (esc_idx + escaped_search.length);
        label.set_markup (before + "<b><u>" + match + "</u></b>" + after);
    }

    private bool filter_tree_func (GLib.Object item) {
        if (search_text == "") return true;
        var row = item as Gtk.TreeListRow;
        if (row == null) return true;
        var dir_item = row.get_item () as DirectoryItem;
        if (dir_item == null) return true;

        // 直接查匹配缓存: 命中表示自身或其子树中存在名称匹配
        return matching_paths.contains (dir_item.path);
    }

    // 预计算搜索匹配缓存: 自底向上遍历整棵树, 把自身名称匹配、或其子树含匹配的
    // 所有节点 path 加入 matching_paths。filter_tree_func 之后只查表, 不再递归。
    private void rebuild_matching_cache () {
        matching_paths.clear ();
        if (search_text == "") return;
        string lower_search = search_text.casefold ();
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            collect_matching_paths ((DirectoryItem) root_store.get_item (i), lower_search);
        }
    }

    // 返回当前子树(含自身)是否含匹配; 含则把自身 path 记入缓存并向上冒泡
    private bool collect_matching_paths (DirectoryItem item, string lower_search) {
        bool self_match = item.name.casefold ().contains (lower_search);
        bool descendant_match = false;
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = item.children.get_item (i) as DirectoryItem;
            if (child == null) continue;
            if (collect_matching_paths (child, lower_search)) {
                descendant_match = true;
            }
        }
        if (self_match || descendant_match) {
            matching_paths.add (item.path);
            return true;
        }
        return false;
    }

    // 由 FileTreeFactory 通过 CheckToggled Hook 调用 (factory 内部已把 notify 信号
    // 的 (Object, ParamSpec) 签名包装成 (CheckButton)).
    private void on_check_toggled (Gtk.CheckButton check) {
        var item = check.get_data<DirectoryItem> ("item");
        if (item == null) return;

        push_undo_state ();

        bool new_checked = check.active;
        // 统一入口: 通过 check_model 修改状态, 再同步 items 和 UI
        apply_check_change (item, new_checked);
    }

    // 统一的勾选变更处理: 修改 check_model -> 同步 items -> 刷新 UI 三态
    private void apply_check_change (DirectoryItem item, bool new_checked) {
        if (item.is_dir) {
            // 立即更新 checked_dirs 确保未展开目录状态正确
            check_model.set_dir_checked (item.path, new_checked);
            refresh_tree_state_for_path (item);
            dir_column_view.queue_draw ();

            // 目录: 后台线程递归收集文件路径和子目录路径, 完成后在主线程更新 UI, 避免阻塞
            string dir_path = item.path;
            try {
                GLib.Thread<void*>? thread = null;
                thread = new Thread<void*> ("collect-files", () => {
                    var file_paths = new Gee.ArrayList<string> ();
                    var dir_paths = new Gee.ArrayList<string> ();
                    collect_files_from_filesystem (dir_path, file_paths, dir_paths);
                    Idle.add (() => {
                        if (app_state.window_closing) {
                            return Source.REMOVE;
                        }
                        apply_dir_check_result (new_checked, dir_paths, file_paths);
                        if (thread != null) app_state.bg_threads.remove (thread);
                        return Source.REMOVE;
                    });
                    return null;
                });
                app_state.bg_threads.add (thread);
            } catch (ThreadError e) {
                warning ("Failed to create collect-files thread: %s", e.message);
                // 后备: 同步执行
                var file_paths = new Gee.ArrayList<string> ();
                var dir_paths = new Gee.ArrayList<string> ();
                collect_files_from_filesystem (dir_path, file_paths, dir_paths);
                apply_dir_check_result (new_checked, dir_paths, file_paths);
            }
        } else {
            // 文件: 直接切换 (无 I/O, 同步即可)
            check_model.toggle_file (item.path);
            ItemData? binary_item = null;
            if (new_checked) {
                if (!path_in_items (item.path)) {
                    var new_item = new ItemData ("file", item.path, null, false);
                    items.add (new_item);
                    if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        binary_item = new_item;
                    }
                }
            } else {
                remove_items_by_path (item.path);
            }
            refresh_tree_state_for_path (item);
            dir_column_view.queue_draw ();
            refresh_list ();
            if (binary_item != null) {
                enqueue_item_for_preprocess (binary_item);
            }
        }
    }

    // 目录勾选/取消勾选的后台收集结果处理 (主线程)
    // items 增删分批在 Idle 中执行, 避免数万文件一次性处理阻塞 UI
    private void apply_dir_check_result (bool new_checked, Gee.ArrayList<string> dir_paths, Gee.ArrayList<string> file_paths) {
        uint my_token = current_operation_token + 1;
        current_operation_token = my_token;
        string op_dir = dir_paths.size > 0 ? dir_paths.get (0) : "";
        if (op_dir != "") {
            dir_operation_tokens.set (op_dir, my_token);
        }
        // check_model 操作: 同步执行 (数据结构操作, 相对快速)
        if (new_checked) {
            // 先加文件 (内部会移除祖先目录的 checked_dirs 标记)
            check_model.add_files ((string[]) file_paths.to_array ());
            // 再把当前目录及其所有子孙目录加回 checked_dirs
            foreach (var d in dir_paths) {
                check_model.set_dir_checked (d, true);
            }
        } else {
            foreach (var d in dir_paths) {
                check_model.set_dir_checked (d, false);
            }
            check_model.remove_files ((string[]) file_paths.to_array ());
            // 将取消勾选的目录的祖先从 checked_dirs 中移除, 使其降级为半选
            check_model.remove_ancestors_from_checked_dirs (dir_paths.get (0));
        }
        // 树状态刷新 (基于 check_model, 已同步更新)
        // 增量: 从被勾目录向上重算受影响的子树与祖先链, 避免全树递归
        refresh_tree_state_for_path_str (op_dir != "" ? op_dir : dir_paths.get (0));
        dir_column_view.queue_draw ();

        // items 增删: 分批在 Idle 中执行, 每批 200 个, 避免阻塞主循环
        int chunk_size = 200;
        int idx = 0;
        Idle.add (() => {
            if (app_state.window_closing) return Source.REMOVE;
            if (op_dir != "" && dir_operation_tokens.has_key (op_dir) && dir_operation_tokens.get (op_dir) != my_token) return Source.REMOVE;
            int count = 0;
            while (idx < file_paths.size && count < chunk_size) {
                var p = file_paths.get (idx);
                if (new_checked) {
                    if (!path_in_items (p)) {
                        var new_item = new ItemData ("file", p, null, false);
                        items.add (new_item);
                        if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                            enqueue_item_for_preprocess (new_item);
                        }
                    }
                } else {
                    remove_items_by_path (p);
                }
                idx++;
                count++;
            }
            if (idx < file_paths.size) {
                return Source.CONTINUE;
            }
            if (!app_state.window_closing && (op_dir == "" || !dir_operation_tokens.has_key (op_dir) || dir_operation_tokens.get (op_dir) == my_token)) {
                refresh_list ();
            }
            return Source.REMOVE;
        });
    }

    // 从文件系统递归收集目录下所有文件路径和子目录路径
    private void collect_files_from_filesystem (string dir_path, Gee.ArrayList<string> out_files, Gee.ArrayList<string> out_dirs) {
        if (app_state.app_cancellable != null && app_state.app_cancellable.is_cancelled ()) return;
        out_dirs.add (dir_path);
        var dir = File.new_for_path (dir_path);
        string[] ignored_dirs = ConfigManager.get_ignored_dirs ();
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE + "," + FileAttribute.STANDARD_IS_SYMLINK,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS
            );
            FileInfo info;
            while ((info = enumerator.next_file ()) != null) {
                if (app_state.app_cancellable != null && app_state.app_cancellable.is_cancelled ()) return;
                string child_name = info.get_name ();
                if (child_name == ".filecollector_cache") continue;
                if (child_name in ignored_dirs) continue;
                var child = dir.get_child (child_name);
                if (info.get_is_symlink () && info.get_file_type () == FileType.DIRECTORY) {
                    continue;
                }
                if (info.get_file_type () == FileType.DIRECTORY) {
                    collect_files_from_filesystem (child.get_path (), out_files, out_dirs);
                } else {
                    out_files.add (child.get_path ());
                }
            }
        } catch (Error e) {
            warning ("collect_files_from_filesystem: %s", e.message);
        }
    }

    // 从 check_model 重新计算所有可见节点的三态
    // 辅助结构体：自底向上递归中收集子树统计信息, 消除双重递归
    private struct SubtreeStats {
        public int total_files;
        public int checked_files;
        public bool has_unloaded_descendants;
        public bool all_unloaded_in_checked_dirs;
    }

    private void refresh_all_tree_states () {
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            refresh_and_collect_stats ((DirectoryItem) root_store.get_item (i));
        }
    }

    // 自底向上刷新并收集统计信息, 取代原先分散的 refresh_subtree_states 递归 + 独立统计计算
    private SubtreeStats refresh_and_collect_stats (DirectoryItem item) {
        SubtreeStats stats = SubtreeStats ();

        if (!item.is_dir) {
            // 文件节点：直接查 check_model
            bool is_checked = item.path in check_model.checked_files;
            item.checked = is_checked;
            item.inconsistent = false;

            stats.total_files = 1;
            stats.checked_files = is_checked ? 1 : 0;
            return stats;
        }

        // 目录节点：先递归处理所有子节点, 顺带收集统计
        stats.total_files = 0;
        stats.checked_files = 0;
        stats.has_unloaded_descendants = false;
        stats.all_unloaded_in_checked_dirs = true; // 默认真空为真
        for (uint i = 0; i < item.children.get_n_items (); i++) {
            var child = (DirectoryItem) item.children.get_item (i);
            var child_stats = refresh_and_collect_stats (child);
            stats.total_files += child_stats.total_files;
            stats.checked_files += child_stats.checked_files;
            if (child_stats.has_unloaded_descendants) {
                stats.has_unloaded_descendants = true;
                if (!child_stats.all_unloaded_in_checked_dirs) {
                    stats.all_unloaded_in_checked_dirs = false;
                }
            }
            // 子目录未加载时, 其后代文件不在树中, stats 无法覆盖
            if (child.is_dir && !child.children_loaded) {
                stats.has_unloaded_descendants = true;
                // 未加载的子目录若不在 checked_dirs 中, 则无法确认其后代是否全选
                if (!(child.path in check_model.checked_dirs)) {
                    stats.all_unloaded_in_checked_dirs = false;
                }
            }
        }

        // 根据子节点统计结果推导当前目录的三态 (统一状态机)
        bool has_checked = check_model.has_checked_descendant (item.path);
        bool in_checked_dirs = item.path in check_model.checked_dirs;

        if (stats.total_files > 0) {
            if (in_checked_dirs) {
                // 用户显式勾选该目录，但子文件可能还在后台加入 checked_files，或用户手动取消了部分
                if (stats.checked_files < stats.total_files) {
                    item.checked = false;
                    item.inconsistent = true; // 半选 (加载中或部分取消)
                } else {
                    item.checked = true;
                    item.inconsistent = false; // 全选
                }
            } else {
                // 目录未被显式勾选，状态完全由已加载的子文件决定
                if (stats.checked_files == 0) {
                    item.checked = false;
                    item.inconsistent = has_checked; // 若未加载的深层后代有选中，则半选；否则未选
                } else if (stats.checked_files == stats.total_files
                           && (!stats.has_unloaded_descendants || stats.all_unloaded_in_checked_dirs)) {
                    // 所有已加载文件均勾选, 且无未加载后代或未加载后代均在 checked_dirs 中 → 确认全选
                    item.checked = true;
                    item.inconsistent = false;
                } else {
                    // 有未加载后代且不在 checked_dirs 中, 无法确认是否所有文件均勾选 → 半选 (保守)
                    item.checked = false;
                    item.inconsistent = true;
                }
            }
        } else {
            // 空目录或未加载子节点的目录 (懒加载占位逻辑)
            // checked_dirs 已在项目加载时清理过时条目 (移除有缺失文件的目录)
            // 因此 in_checked_dirs 可靠地表示全选态
            if (in_checked_dirs) {
                item.checked = true;
                item.inconsistent = false; // 全选态 (占位)
            } else if (has_checked) {
                // 若所有未加载后代均在 checked_dirs 中 (即均为完整勾选的子目录), 视为全选而非半选
                if (stats.all_unloaded_in_checked_dirs) {
                    item.checked = true;
                    item.inconsistent = false;
                } else {
                    item.checked = false;
                    item.inconsistent = true; // 半选态 (占位)
                }
            } else {
                item.checked = false;
                item.inconsistent = false; // 彻底未勾选
            }
        }
        return stats;
    }

    // 保留兼容接口
    private void refresh_subtree_states (DirectoryItem item) {
        refresh_and_collect_stats (item);
    }

    // ─── 增量刷新 (问题4): 只刷新受影响子树 + 向上父链 ────────────────
    // DirectoryItem 无 parent 指针, 故按 path 在树中查找节点

    // 按 path 在目录树中递归查找 DirectoryItem
    private DirectoryItem? find_directory_item_by_path (DirectoryItem? root, string target_path) {
        if (root == null) return null;
        if (root.path == target_path) return root;
        for (uint i = 0; i < root.children.get_n_items (); i++) {
            var child = root.children.get_item (i) as DirectoryItem;
            var found = find_directory_item_by_path (child, target_path);
            if (found != null) return found;
        }
        return null;
    }

    // 给定某节点, 沿其 path 逐级向上, 找到其在树中的父 DirectoryItem
    private DirectoryItem? find_parent_directory_item (DirectoryItem item) {
        var parent_file = File.new_for_path (item.path).get_parent ();
        if (parent_file == null) return null; // 顶层节点
        string parent_path = parent_file.get_path ();
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            var root_item = root_store.get_item (i) as DirectoryItem;
            var found = find_directory_item_by_path (root_item, parent_path);
            if (found != null) return found;
        }
        return null;
    }

    // 增量刷新: 重算 item 自身子树的三态, 再沿祖先链逐层向上重算,
    // 避免 refresh_all_tree_states 对全树做无谓递归。
    private void refresh_tree_state_for_path (DirectoryItem item) {
        refresh_and_collect_stats (item);
        var parent = find_parent_directory_item (item);
        while (parent != null) {
            refresh_and_collect_stats (parent);
            parent = find_parent_directory_item (parent);
        }
    }

    // 按 path 增量刷新 (外部已知 path 时调用)
    private void refresh_tree_state_for_path_str (string path) {
        DirectoryItem? target = null;
        for (uint i = 0; i < root_store.get_n_items (); i++) {
            var root_item = root_store.get_item (i) as DirectoryItem;
            target = find_directory_item_by_path (root_item, path);
            if (target != null) break;
        }
        if (target != null) {
            refresh_tree_state_for_path (target);
        }
    }

    private void push_undo_state () {
        undo_manager.push (new UndoDelta.for_snapshot (
            new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header)));
    }

    private void push_undo_delta (UndoDelta delta) {
        undo_manager.push (delta);
    }

    private int find_item_index (ItemData data) {
        for (int i = 0; i < items.size; i++) {
            if (items.get (i) == data) return i;
        }
        return -1;
    }

    private void on_undo () {
        undo_manager.set_in_progress (true);
        var delta = undo_manager.pop_undo ();
        if (delta == null) { undo_manager.set_in_progress (false); return; }
        var redo_delta = build_redo_delta (delta);
        apply_undo_delta (delta);
        undo_manager.push_redo (redo_delta);
        undo_manager.set_in_progress (false);
        if (delta.op != UndoOp.SNAPSHOT) {
            refresh_list ();
        }
        update_action_sensitivity ();
    }

    private void on_redo () {
        undo_manager.set_in_progress (true);
        var delta = undo_manager.pop_redo ();
        if (delta == null) { undo_manager.set_in_progress (false); return; }
        var undo_delta = build_undo_delta (delta);
        apply_redo_delta (delta);
        undo_manager.push_undo (undo_delta);
        undo_manager.set_in_progress (false);
        if (delta.op != UndoOp.SNAPSHOT) {
            refresh_list ();
        }
        update_action_sensitivity ();
    }

    // 根据 undo delta 构建对应的 redo delta (捕获当前状态作为 redo 依据)
    private UndoDelta build_redo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
            case UndoOp.INSERT:
                // redo = 重新插入同样的 items
                return new UndoDelta.for_insert (d.index, d.items);
            case UndoOp.REMOVE:
                // redo = 再次移除
                return new UndoDelta.for_remove (d.index, d.items, d.removed_checked_paths);
            case UndoOp.EDIT:
                return new UndoDelta.for_edit (d.index, d.old_content, d.new_content);
            case UndoOp.SWAP:
                return new UndoDelta.for_swap (d.index, d.index2);
            case UndoOp.MOVE:
                return new UndoDelta.for_move (d.from_index, d.to_index);
            case UndoOp.SET_ABSOLUTE:
                return new UndoDelta.for_absolute (d.old_bool_value, d.new_bool_value,
                                                    d.old_show_header, show_header);
            case UndoOp.SET_HEADER:
                return new UndoDelta.for_header (d.old_bool_value, d.new_bool_value);
            default:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
        }
    }

    // 根据 redo delta 构建对应的 undo delta
    private UndoDelta build_undo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
            case UndoOp.INSERT:
                return new UndoDelta.for_insert (d.index, d.items);
            case UndoOp.REMOVE:
                return new UndoDelta.for_remove (d.index, d.items, d.removed_checked_paths);
            case UndoOp.EDIT:
                return new UndoDelta.for_edit (d.index, d.old_content, d.new_content);
            case UndoOp.SWAP:
                return new UndoDelta.for_swap (d.index, d.index2);
            case UndoOp.MOVE:
                return new UndoDelta.for_move (d.from_index, d.to_index);
            case UndoOp.SET_ABSOLUTE:
                return new UndoDelta.for_absolute (d.old_bool_value, d.new_bool_value,
                                                    d.old_show_header, show_header);
            case UndoOp.SET_HEADER:
                return new UndoDelta.for_header (d.old_bool_value, d.new_bool_value);
            default:
                return new UndoDelta.for_snapshot (
                    new UndoState (items, check_model.checked_files, check_model.checked_dirs, work_dir, use_absolute, show_header));
        }
    }

    private void apply_undo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                restore_undo_state (d.snapshot);
                return;
            case UndoOp.INSERT:
                // undo 插入 = 移除
                for (int i = 0; i < d.items.size; i++) items.remove_at (d.index);
                break;
            case UndoOp.REMOVE:
                // undo 移除 = 重新插入
                for (int i = 0; i < d.items.size; i++) {
                    items.insert (d.index + i, d.items.get (i));
                }
                if (d.removed_checked_paths != null) {
                    for (int i = 0; i < d.removed_checked_paths.size; i++) {
                        set_tree_item_check (d.removed_checked_paths.get (i), true);
                    }
                }
                break;
            case UndoOp.EDIT:
                items.get (d.index).content = d.old_content;
                break;
            case UndoOp.SWAP:
                var tmp = items.get (d.index);
                items.set (d.index, items.get (d.index2));
                items.set (d.index2, tmp);
                break;
            case UndoOp.MOVE:
                // undo: 从 to_index 移回 from_index
                if (d.to_index < 0 || d.to_index >= items.size ||
                    d.from_index < 0 || d.from_index > items.size) break;
                var it = items.get (d.to_index);
                items.remove_at (d.to_index);
                items.insert (d.from_index, it);
                break;
            case UndoOp.SET_ABSOLUTE:
                apply_absolute_change (d.old_bool_value, d.old_show_header);
                break;
            case UndoOp.SET_HEADER:
                apply_header_change (d.old_bool_value);
                break;
        }
    }

    private void apply_redo_delta (UndoDelta d) {
        switch (d.op) {
            case UndoOp.SNAPSHOT:
                restore_undo_state (d.snapshot);
                return;
            case UndoOp.INSERT:
                for (int i = 0; i < d.items.size; i++) {
                    items.insert (d.index + i, d.items.get (i));
                }
                break;
            case UndoOp.REMOVE:
                for (int i = 0; i < d.items.size; i++) items.remove_at (d.index);
                if (d.removed_checked_paths != null) {
                    for (int i = 0; i < d.removed_checked_paths.size; i++) {
                        set_tree_item_check (d.removed_checked_paths.get (i), false);
                    }
                }
                break;
            case UndoOp.EDIT:
                items.get (d.index).content = d.new_content;
                break;
            case UndoOp.SWAP:
                var tmp = items.get (d.index);
                items.set (d.index, items.get (d.index2));
                items.set (d.index2, tmp);
                break;
            case UndoOp.MOVE:
                if (d.from_index < 0 || d.from_index >= items.size ||
                    d.to_index < 0 || d.to_index > items.size) break;
                var it = items.get (d.from_index);
                items.remove_at (d.from_index);
                items.insert (d.to_index, it);
                break;
            case UndoOp.SET_ABSOLUTE:
                apply_absolute_change (d.new_bool_value, d.new_show_header);
                break;
            case UndoOp.SET_HEADER:
                apply_header_change (d.new_bool_value);
                break;
        }
    }

    // 同步单选按钮到 use_absolute 状态
    private void sync_path_mode_radios () {
        block_option_signals ();
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        unblock_option_signals ();
    }

    // 同步头部复选框到 show_header 状态
    private void sync_header_checkbox () {
        block_option_signals ();
        check_write_header.active = show_header;
        unblock_option_signals ();
    }

    private void block_option_signals () {
        if (handler_path_abs != 0) SignalHandler.block (radio_absolute_path, handler_path_abs);
        if (handler_path_rel != 0) SignalHandler.block (radio_relative_path, handler_path_rel);
        if (handler_header != 0) SignalHandler.block (check_write_header, handler_header);
    }

    private void unblock_option_signals () {
        if (handler_path_abs != 0) SignalHandler.unblock (radio_absolute_path, handler_path_abs);
        if (handler_path_rel != 0) SignalHandler.unblock (radio_relative_path, handler_path_rel);
        if (handler_header != 0) SignalHandler.unblock (check_write_header, handler_header);
    }

    // 根据 work_dir 更新窗口标题/副标题
    private void update_title () {
        if (work_dir != null) {
            update_subtitle (work_dir.get_path ());
        } else {
            update_subtitle (null);
        }
    }

    private void setup_empty_state () {
        // 创建空状态页面
        empty_page_widget = new Adw.StatusPage ();
        empty_page_widget.icon_name = "folder-open-symbolic";
        empty_page_widget.title = _("No Working Directory Selected");
        empty_page_widget.add_css_class ("empty-page");
        // 常态即离窗口 18px 四周, 与正常三栏整体 (outer_paned 的 margin-start/end: 18)
        // 到窗口的距离一致. 这样拖拽高亮框 (画在 widget 边缘的 inset 描边) 距窗口
        // 也是 18px, 而非贴边.
        // 注意: 用 margin 而非 padding, 因为 inset box-shadow 始终画在 border 内侧,
        // padding 不会让描边内缩, 只有 widget 自身离窗口才能拉开高亮框距离.
        empty_page_widget.margin_start = 18;
        empty_page_widget.margin_end = 18;
        empty_page_widget.margin_bottom = 18;
        empty_page_widget.description = _("Open a folder as the working directory to start collecting and orchestrating files.");

        var empty_btn = new Gtk.Button ();
        empty_btn.set_label (_("Open Working Directory"));
        empty_btn.add_css_class ("suggested-action");
        empty_btn.add_css_class ("pill");
        empty_btn.halign = Gtk.Align.CENTER;
        empty_btn.clicked.connect (() => on_open_folder_clicked.begin ());
        empty_page_widget.child = empty_btn;

        // 首次打开 (无工作目录) 时允许直接拖入文件/文件夹设定工作目录, 无需先点按钮.
        // 文件夹取其自身, 文件取其父目录 (见 on_external_drop_on_empty_state).
        var empty_drop = new Gtk.DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
        empty_drop.enter.connect (() => { set_external_drop_highlight (empty_page_widget, true); return Gdk.DragAction.COPY; });
        empty_drop.leave.connect (() => { set_external_drop_highlight (empty_page_widget, false); });
        empty_drop.drop.connect (on_external_drop_on_empty_state);
        empty_page_widget.add_controller (empty_drop);

        update_empty_state ();
    }

    private void update_empty_state () {
        // 主内容 ToolbarView 现在位于 snapshot_split 内, 直接通过字段引用,
        // 不再从 toast_overlay.child 强转 (它现在是 AdwOverlaySplitView)。
        Adw.ToolbarView? toolbar_view = main_view;

        bool show_empty = (work_dir == null) || (is_git_mode && !git_panel.has_data ());
        bool no_workdir = (work_dir == null);

        if (show_empty) {
            // 替换 ToolbarView 的 content 为空状态页面
            if (toolbar_view != null && saved_toolbar_content == null && toolbar_view.content != null) {
                saved_toolbar_content = toolbar_view.content;
                if (is_git_mode) {
                    git_panel.configure_empty_page ();
                    toolbar_view.content = git_panel.empty_page_widget;
                } else {
                    toolbar_view.content = empty_page_widget;
                }
            }

            // 简化标题栏 (仅未设置工作目录时隐藏按钮, git 模式保留所有按钮方便返回)
            if (no_workdir) {
                btn_ai_toggle.visible = false;
                open_folder_btn.visible = false;
                btn_toggle_git.visible = false;
                btn_global_search.visible = false;
                // 工作区侧栏按钮: 首次打开 (无工作目录) 时侧栏无意义, 一并隐藏
                btn_toggle_snapshot.visible = false;
            }
        } else {
            // 恢复 ToolbarView 的 content
            if (toolbar_view != null && saved_toolbar_content != null) {
                toolbar_view.content = saved_toolbar_content;
                saved_toolbar_content = null;
            }

            // 恢复标题栏所有按钮
            btn_ai_toggle.visible = true;
            open_folder_btn.visible = true;
            btn_toggle_git.visible = true;
            btn_global_search.visible = true;
            btn_toggle_snapshot.visible = true;
        }
    }

    // 统一应用 use_absolute 变更 (undo/redo 共用)
    private void apply_absolute_change (bool new_abs, bool new_hdr) {
        use_absolute = new_abs;
        show_header = new_hdr;
        block_option_signals ();
        radio_absolute_path.active = new_abs;
        radio_relative_path.active = !new_abs;
        check_write_header.active = new_hdr;
        unblock_option_signals ();
    }

    // 统一应用 show_header 变更 (undo/redo 共用)
    private void apply_header_change (bool new_hdr) {
        show_header = new_hdr;
        block_option_signals ();
        check_write_header.active = new_hdr;
        unblock_option_signals ();
    }

    private void restore_undo_state (UndoState state) {
        items.clear ();
        for (int i = 0; i < state.n_items; i++) {
            items.add (state.get_item (i));
        }

        check_model.replace_from (state.checked_paths, state.checked_dirs);

        use_absolute = state.use_absolute;
        show_header = state.show_header;
        block_option_signals ();
        radio_absolute_path.active = use_absolute;
        radio_relative_path.active = !use_absolute;
        check_write_header.active = show_header;
        unblock_option_signals ();

        bool work_dir_changed = false;
        if (state.work_dir != null && work_dir != null) {
            work_dir_changed = state.work_dir.get_path () != work_dir.get_path ();
        } else if (state.work_dir != null || work_dir != null) {
            work_dir_changed = true;
        }

        if (work_dir_changed) {
            work_dir = state.work_dir;
            if (work_dir != null) {
                update_subtitle (work_dir.get_path ());
                root_store.remove_all ();
                var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
                root_store.append (root_item);
                load_directory_children_lazy (root_item);
                search_entry.visible = true;
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) root_row.set_expanded (true);
            } else {
                update_subtitle (null);
                root_store.remove_all ();
                search_entry.visible = false;
            }
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            refresh_all_tree_states ();
        }

        refresh_list ();
        update_action_sensitivity ();
        update_workdir_dependent_buttons ();
    }

    private void setup_signals () {
        open_folder_btn.clicked.connect (() => on_open_folder_clicked.begin ());
        btn_add_ext.clicked.connect (on_add_external_files);
        btn_add_text_above.clicked.connect (() => insert_text (true));
        btn_add_text_below.clicked.connect (() => insert_text (false));
        btn_move_up.clicked.connect (on_move_up);
        btn_move_down.clicked.connect (on_move_down);
        btn_delete.clicked.connect (on_delete_item);
        btn_clear.clicked.connect (on_clear_items_with_confirm);
        btn_generate.clicked.connect (on_generate_clicked);
        radio_absolute_path.notify["active"].connect (on_path_mode_changed);
        radio_relative_path.notify["active"].connect (on_path_mode_changed);
        check_write_header.notify["active"].connect (on_header_check_changed);
        btn_ai_toc.clicked.connect (on_ai_toc_clicked);

        queue_selection.selection_changed.connect (on_queue_selection_changed);
        queue_list.activate.connect (on_queue_row_activated);

        search_entry.search_changed.connect (on_search_changed);

        update_queue_buttons ();
        update_workdir_dependent_buttons ();
    }

    // ─── Git 模式 ────────────────────────────────────────────────────────

    private void init_git_panel () {
        // 注册 left / action stack 页面名 (原 setup_git_view 的窗口布局部分)
        left_stack.get_page (tree_page).set_name ("tree_page");
        left_stack.get_page (git_page).set_name ("git_page");
        action_stack.get_page (normal_actions).set_name ("normal_actions");
        action_stack.get_page (git_actions).set_name ("git_actions");
        left_stack.visible_child = tree_page;
        action_stack.visible_child = normal_actions;

        setup_dir_load_ui ();

        git_panel = new GitHistoryPanel (
            this, app_state,
            git_page, git_list_view, git_scrolled, git_search_entry, git_actions,
            btn_git_add_all_changed, btn_git_export_working_diff, btn_git_export_commit_diff,
            btn_git_delete, btn_git_clear,
            preview_view, preview_stack, btn_retry_preprocess
        );
        git_panel.refresh_list_requested.connect (refresh_list);
        git_panel.undo_snapshot_requested.connect (() => push_undo_state ());
        git_panel.preprocess_item_requested.connect ((path) => {
            var it = find_item_by_path (path);
            if (it != null) enqueue_item_for_preprocess (it);
        });
        git_panel.toast.connect ((msg) => show_toast (msg));
        git_panel.error.connect ((title, msg) => show_error (title, msg));
        git_panel.empty_state_changed.connect (update_empty_state);
        git_panel.refresh_tree_states_requested.connect (refresh_all_tree_states);
        git_panel.delete_requested.connect (on_delete_item);
        git_panel.clear_requested.connect (on_clear_items_with_confirm);

        btn_toggle_git.clicked.connect (on_toggle_git_mode);
        btn_global_search.clicked.connect (on_global_search);
    }

    // 目录加载进度条 (原 setup_git_view 中构建, 属目录树, 待任务 #8 迁入 DirectoryController)
    private void setup_dir_load_ui () {
        dir_load_label = new Gtk.Label (null);
        dir_load_label.xalign = 0;
        dir_load_label.add_css_class ("dim-label");
        dir_load_label.add_css_class ("caption");

        dir_load_progress = new Gtk.ProgressBar ();
        dir_load_progress.add_css_class ("osd");

        var dir_load_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        dir_load_box.margin_start = 12;
        dir_load_box.margin_end = 12;
        dir_load_box.margin_bottom = 6;
        dir_load_box.append (dir_load_label);
        dir_load_box.append (dir_load_progress);

        dir_load_revealer = new Gtk.Revealer ();
        dir_load_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
        dir_load_revealer.reveal_child = false;
        dir_load_revealer.set_child (dir_load_box);

        var parent_box = left_stack.get_parent () as Gtk.Box;
        if (parent_box != null) {
            parent_box.append (dir_load_revealer);
        }
    }

    private void on_toggle_git_mode () {
        is_git_mode = !is_git_mode;
        git_panel.is_git_mode = is_git_mode;

        if (is_git_mode) {
            left_stack.visible_child_name = "git_page";
            action_stack.visible_child_name = "git_actions";
            btn_toggle_git.icon_name = "folder-symbolic";
            btn_toggle_git.tooltip_text = _("Switch to file tree");
            lbl_left_title.label = _("Git Commit History");
            git_panel.maybe_load_history ();
        } else {
            left_stack.visible_child_name = "tree_page";
            action_stack.visible_child_name = "normal_actions";
            btn_toggle_git.icon_name = "xsi-git-symbolic";
            btn_toggle_git.tooltip_text = _("Switch to Git commit history");
            lbl_left_title.label = _("File Browser");
        }
        update_empty_state ();
    }

    // ─── 语法高亮 ────────────────────────────────────────────────────────

    private PreviewSyntaxManager? syntax_manager;

    private void setup_preview_syntax () {
        syntax_manager = new PreviewSyntaxManager (preview_view);
    }

    private void setup_preview_signals () {
        preview_scrolled.edge_reached.connect ((pos) => {
            if (pos == Gtk.PositionType.BOTTOM) {
                load_preview_chunk.begin ();
            }
        });

        preview_scrolled.get_vadjustment ().value_changed.connect (() => {
            var adj = preview_scrolled.get_vadjustment ();
            double bottom = adj.get_upper () - adj.get_page_size ();
            preview_auto_scroll = (adj.get_value () >= bottom - 30);
        });
    }

    private void apply_preview_scheme () {
        if (syntax_manager != null) syntax_manager.apply_scheme ();
    }

    private GtkSource.Language? guess_language (string? file_path) {
        return syntax_manager != null ? syntax_manager.guess_language (file_path) : null;
    }

    private void apply_preview_with_highlight (string text, string? file_path) {
        preview_stack.visible_child = preview_view;
        if (syntax_manager != null) {
            syntax_manager.apply_with_highlight (text, file_path);
        }
        // 滚动归零与自动滚动复位统一在 update_preview() 入口处理 (代码与 Markdown
        // 预览共用), 此处仅负责 GtkSourceView 的内容渲染.
    }

    private void apply_preview_no_highlight (string text) {
        preview_stack.visible_child = preview_view;
        if (syntax_manager != null) {
            syntax_manager.apply_no_highlight (text);
        }
    }

    // ─── VLM 预处理队列 ────────────────────────────────────────────────

    private void setup_vlm_queue () {
        vlm_controller = new VlmQueueController (app_state);
        // Controller 在 task_completed 中已更新 ItemData 属性, 仅把刷新请求
        // 委托回 Window (Window 才知道如何合并刷新以避免 O(n) 扫描 + 预览级联).
        vlm_controller.refresh_list_requested.connect (schedule_refresh_list);

        // 用 Gtk.Overlay 包裹 ToolbarView, 使进度卡片能悬浮在窗口右下角.
        // overlay reparenting 留在 Window: 涉及 Window 模板绑定的 [GtkChild]
        // main_view 和 Window 私有的 snapshot_split, Controller 不应接触这些.
        main_overlay = new Gtk.Overlay ();
        // main_view 当前是 snapshot_split.content, 需先摘除再挂入 overlay,
        // 否则 gtk_overlay_set_child 会因 main_view 已持有父节点而报断言错误。
        snapshot_split.content = null;
        main_overlay.child = main_view;
        main_overlay.add_overlay (vlm_controller.progress_revealer);
        snapshot_split.content = main_overlay;
    }

    // 调用方包装: 保留为 thin wrapper 避免更新 9 个调用点. 状态守卫和并发数同步
    // 已下沉到 VlmQueueController.enqueue.
    private void enqueue_item_for_preprocess (ItemData item) {
        vlm_controller.enqueue (item);
    }

    // ─── Keyboard Shortcuts ───────────────────────────────────────────────

    private void setup_shortcuts () {
        ShortcutsHelper.setup (
            this,
            () => { on_generate_clicked (); },
            () => { on_generate_to_clipboard_clicked (); },
            () => { on_undo (); },
            () => { on_redo (); },
            () => { on_clear_items_with_confirm (); },
            () => { on_delete_item (); },
            () => { on_move_up (); },
            () => { on_move_down (); },
            () => { on_add_external_files (); },
            () => { insert_text (true); },
            () => { insert_text (false); },
            () => { toggle_ai_panel (); },
            () => { on_global_search (); }
        );

        var export_zip_act = new GLib.SimpleAction ("export_zip", null);
        export_zip_act.activate.connect (() => { on_export_zip_clicked (); });
        add_action (export_zip_act);

        // 快捷键 Action 在 setup 后才创建, 需要重新同步一次状态
        update_queue_buttons ();
        update_workdir_dependent_buttons ();
    }

    // ─── 工作区快照栏 ────────────────────────────────────────────────────

    // 在 Vala 中构建快照侧栏与 AdwOverlaySplitView。
    // blueprint 0.19 不能为 OverlaySplitView 正确指派 sidebar/content 子控件,
    // 故在此显式 set_sidebar()/set_content(), 确保侧栏能正常分配尺寸并渲染。
    private void build_snapshot_split_view () {
        // 侧栏: 顶部 "Workspaces" 标题栏 + 新建按钮
        var sidebar_header = new Adw.HeaderBar ();
        sidebar_header.title_widget = new Adw.WindowTitle (_("Workspaces"), "");
        btn_new_snapshot = new Gtk.Button.from_icon_name ("list-add-symbolic");
        btn_new_snapshot.tooltip_text = _("Save Current State as New Snapshot");
        sidebar_header.pack_end (btn_new_snapshot);

        // 侧栏列表: AdwSidebar + 空状态占位
        snapshot_sidebar = new Adw.Sidebar ();
        var snapshot_menu = new GLib.Menu ();
        var sec1 = new GLib.Menu ();
        sec1.append (_("Rename Snapshot"), "win.rename_snapshot");
        sec1.append (_("Change Icon..."), "win.change_snapshot_icon");
        sec1.append (_("Save Snapshot As Project..."), "win.snapshot_save_as");
        snapshot_menu.append_section (null, sec1);
        var sec2 = new GLib.Menu ();
        sec2.append (_("Delete Snapshot"), "win.delete_snapshot");
        snapshot_menu.append_section (null, sec2);
        snapshot_sidebar.menu_model = snapshot_menu;

        var placeholder = new Adw.StatusPage ();
        placeholder.icon_name = "view-grid-symbolic";
        placeholder.title = _("No Snapshots");
        placeholder.description = _("Save the current state as a new snapshot with the + button above.");
        snapshot_sidebar.placeholder = placeholder;

        var sidebar_view = new Adw.ToolbarView ();
        sidebar_view.add_top_bar (sidebar_header);
        sidebar_view.content = snapshot_sidebar;

        // 主内容区: 复用蓝图中的 main_view
        snapshot_split = new Adw.OverlaySplitView ();
        snapshot_split.collapsed = false;
        // pin_sidebar: 折叠/展开 (collapsed 变化) 时不自动显隐侧栏,
        // 可见性完全由 show-sidebar (顶栏开关按钮) 控制, 窄屏覆盖模式下按钮仍可用.
        snapshot_split.pin_sidebar = true;
        // 初始可见性不在此设置: 下方按钮 active<->show-sidebar 双向绑定 (SYNC_CREATE)
        // 会以按钮初始 active=false (BLP) 覆盖, 即启动时侧栏隐藏、按钮呈未按下态.
        snapshot_split.sidebar_position = Gtk.PackType.START;
        // 侧栏宽度固定 280px (min=max): 并排 (docked) 与覆盖 (overlay) 两种模式同宽,
        // 且 "当前宽度是否容得下并排侧栏" 的判定 (见 update_sidebars_layout) 只依赖
        // 常量, 不会随窗口宽度漂移. 比例式宽度 (原 0.20) 会让判定阈值随之变动, 弃用.
        snapshot_split.min_sidebar_width = 280;
        snapshot_split.max_sidebar_width = 280;
        snapshot_split.sidebar = sidebar_view;

        // 响应式: 侧栏并排/覆盖切换不再用静态断点判定 (旧方案只看窗口总宽,
        // 无法区分单开/双开侧栏, 双开时宽度不足导致三卡片被裁切), 改由
        // size_allocate 中的 update_sidebars_layout 按 "窗口宽度是否容得下
        // 三卡片最小宽 + 已展开侧栏宽" 逐个侧栏实时判定, 见该方法注释.

        // 先把 main_view 从 toast_overlay 摘除 (置空 toast_overlay 的 child,
        // 让 GTK 正确解除父子关系), 再挂到 split view 的 content, 否则 GTK 会因
        // main_view 仍被 toast_overlay 持有而拒绝 set_content / 报断言错误。
        toast_overlay.child = null;
        snapshot_split.content = main_view;

        // 将 toast_overlay 的内容替换为带侧栏的 split view
        toast_overlay.child = snapshot_split;
    }

    private void setup_snapshot_sidebar () {
        // 在 Vala 中构建 AdwOverlaySplitView, 因为 blueprint 0.19 无法为
        // OverlaySplitView 正确指派 sidebar/content 子控件 (会导致侧栏整片空白)。
        // 这里显式 set_sidebar()/set_content(), 绕过 blueprint 的子控件分配缺陷。
        build_snapshot_split_view ();

        snapshot_store = new GLib.ListStore (typeof (Adw.SidebarItem));
        snapshot_section = new Adw.SidebarSection ();
        snapshot_sidebar.append (snapshot_section);

        // 应用菜单动作 (重命名 / 另存为 / 删除)
        var rename_act = new GLib.SimpleAction ("rename_snapshot", null);
        rename_act.activate.connect (() => on_rename_snapshot ());
        add_action (rename_act);

        var save_as_act = new GLib.SimpleAction ("snapshot_save_as", null);
        save_as_act.activate.connect (() => on_snapshot_save_as ());
        add_action (save_as_act);

        var del_act = new GLib.SimpleAction ("delete_snapshot", null);
        del_act.activate.connect (() => on_delete_snapshot ());
        add_action (del_act);
        delete_snapshot_act = del_act;

        var icon_act = new GLib.SimpleAction ("change_snapshot_icon", null);
        icon_act.activate.connect (() => on_change_snapshot_icon ());
        add_action (icon_act);

        // 点击某快照 → 切换为该工作区状态。
        // 注意: AdwSidebar.activated 返回的 index 是其内部 flat 索引,
        // 可能与 snapshot_store / app_state.snapshots 的排列顺序不一致
        // (尤其当显示顺序与存储顺序相反时)。因此通过 get_item 取回实际
        // AdwSidebarItem, 再用 index_of_sidebar_item 映射回真实的快照索引,
        // 避免点击错位 (错乱会导致所有点击都加载到同一快照)。
        snapshot_sidebar.activated.connect ((index) => {
            var item = snapshot_sidebar.get_item (index);
            var real_index = index_of_sidebar_item (item);
            if (real_index >= 0) switch_to_snapshot (real_index);
        });

        // 右键菜单: 记录当前项的索引, 供菜单动作使用 (item 可能为 null)
        snapshot_sidebar.setup_menu.connect ((item) => {
            snapshot_selected_index = (int) index_of_sidebar_item (item);
            // 仅剩一个工作区时禁用删除项, 使菜单项直接灰显而非点了才提示.
            update_delete_action_enabled ();
        });

        // 新建快照
        btn_new_snapshot.clicked.connect (() => on_new_snapshot ());

        // 顶栏开关: 展开 / 收起快照栏 (窄屏时自动以覆盖层呈现)
        // 按钮的 active (按下/高亮态) 双向绑定到快照侧栏可见性:
        //   - 侧栏显示时按钮自动呈按下态, 用持久激活态提醒用户功能已开启;
        //   - 点击按钮切换 active 会自动翻转 show_sidebar, 无需手动维护.
        btn_toggle_snapshot.bind_property (
            "active", snapshot_split, "show-sidebar",
            GLib.BindingFlags.BIDIRECTIONAL | GLib.BindingFlags.SYNC_CREATE
        );
        btn_toggle_snapshot.toggled.connect (sync_snapshot_toggle_button);
        // 侧栏开关不一定改变窗口宽度 (覆盖模式不占宽), 此时 size_allocate 不触发,
        // 需显式按当前窗口宽重算两侧并排/覆盖判定 (详见 reevaluate_sidebars).
        snapshot_split.notify["show-sidebar"].connect (reevaluate_sidebars);
        sync_snapshot_toggle_button ();

        // 列表变更 → 重建侧栏
        app_state.snapshots_changed.connect (rebuild_snapshot_sidebar);
        // 列表数量变化 (新建/删除/加载) 时同步删除动作的可用状态
        app_state.snapshots_changed.connect (update_delete_action_enabled);
        // 首次启动 / 无快照时, 保证侧栏至少有一个默认工作区 (Workspace 1)
        app_state.ensure_default_snapshot ();
        active_workspace_index = 0;
        rebuild_snapshot_sidebar ();
        snapshot_sidebar.set_selected (0);

        // 合并导出 (所有快照) 通过快捷键 Ctrl+Shift+E 触发
        var merge_act = new GLib.SimpleAction ("merge_export_snapshots", null);
        merge_act.activate.connect (() => on_merge_export_snapshots ());
        add_action (merge_act);
        GLib.Idle.add (() => {
            var app = this.application;
            if (app != null) {
                app.set_accels_for_action ("win.merge_export_snapshots", { "<Control><Shift>e" });
            }
            return GLib.Source.REMOVE;
        });
    }

    // 仅剩一个工作区时禁用删除动作, 使右键菜单的 Delete 项灰显.
    private void update_delete_action_enabled () {
        if (delete_snapshot_act != null) {
            delete_snapshot_act.set_enabled (app_state.snapshots.size > 1);
        }
    }

    private void rebuild_snapshot_sidebar () {
        snapshot_store.remove_all ();
        snapshot_section.remove_all ();
        for (int i = 0; i < app_state.snapshots.size; i++) {
            var snap = app_state.snapshots.get (i);
            var item = new Adw.SidebarItem (snap.name);
            item.icon_name = snap.icon_name;
            snapshot_store.append (item);
            snapshot_section.append (item);
        }
    }

    // 将当前正在编辑的状态同步回"激活的工作区" (覆盖写, 不触发 snapshots_changed,
    // 因为侧栏只显示名称, 名称未变无需重绘). 这样打开目录 / 编辑后再切换或新建时,
    // 当前内容已归属于 active_workspace_index 对应的 Workspace, 不会游离在列表之外.
    private void sync_active_snapshot () {
        if (active_workspace_index < 0 || active_workspace_index >= app_state.snapshots.size) return;
        var old_snap = app_state.snapshots.get (active_workspace_index);
        var snap = WorkspaceSnapshot.from_app_state (app_state, old_snap.name);
        // from_app_state 会把 icon_name / id / created_at 重置为默认值,
        // 此处保留原快照的展示属性, 否则用户更改的图标会在每次切换 / 新建 / 打开目录
        // 时被静默还原为 view-grid-symbolic, 且唯一 id 也会改变 (影响持久化一致性).
        snap.icon_name = old_snap.icon_name;
        snap.id = old_snap.id;
        snap.created_at = old_snap.created_at;
        app_state.snapshots.set (active_workspace_index, snap);
    }

    // 同步顶栏开关按钮的提示文案 (反映快照栏是否可见).
    // 按钮的按下/高亮态由 active 属性经 bind_property 自动跟随 show_sidebar,
    // 这里只更新 tooltip 以说明当前点击会执行的操作.
    private void sync_snapshot_toggle_button () {
        var visible = btn_toggle_snapshot.active;
        btn_toggle_snapshot.tooltip_text = visible
            ? _("Hide Workspaces Sidebar")
            : _("Show Workspaces Sidebar");
    }

    // 将 AdwSidebarItem 映射回其在 snapshot_store 中的索引 (-1 表示无效)
    private int index_of_sidebar_item (Adw.SidebarItem? item) {
        if (item == null) return -1;
        uint pos;
        return snapshot_store.find (item, out pos) ? (int) pos : -1;
    }

    private void switch_to_snapshot (int index) {
        if (index < 0 || index >= app_state.snapshots.size) return;
        push_undo_state ();
        // 切换前, 先把当前正在编辑的内容存回"旧激活工作区",
        // 否则当前内容会丢失 / 游离. 然后切换到目标并标记为激活.
        sync_active_snapshot ();
        active_workspace_index = index;
        apply_active_snapshot_to_ui ();
    }

    // 将 active_workspace_index 对应的快照应用到 AppState 并同步全部相关 UI.
    // 供 switch_to_snapshot / on_delete_snapshot 复用, 保证切换 / 删除后界面与
    // 当前激活工作区一致. 不调用 sync_active_snapshot (调用方负责, 避免覆盖).
    private void apply_active_snapshot_to_ui () {
        if (active_workspace_index < 0 || active_workspace_index >= app_state.snapshots.size) return;
        app_state.apply_snapshot (active_workspace_index);
        snapshot_sidebar.set_selected ((uint) active_workspace_index);
        // apply_snapshot 通过 replace_from 触发 items_changed / state_changed,
        // 但工作目录是直接写入 app_state (绕过 work_dir 属性 setter), 需在此手动
        // 同步目录树 / 标题 / 空状态, 使切换快照后界面与对应工作区一致.
        var new_work_dir = app_state.work_dir;
        update_subtitle (new_work_dir != null ? new_work_dir.get_path () : _("No working directory set"));
        if (new_work_dir != null) {
            root_store.remove_all ();
            var root_item = new DirectoryItem (new_work_dir.get_basename (), new_work_dir.get_path (), true);
            root_store.append (root_item);
            load_directory_children_lazy (root_item);
            search_entry.visible = true;
            var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
            if (root_row != null) root_row.set_expanded (true);
        } else {
            root_store.remove_all ();
            search_entry.visible = false;
        }
        refresh_list ();
        update_workdir_dependent_buttons ();
        update_empty_state ();
    }

    private void on_new_snapshot () {
        // 直接以默认名创建, 不弹命名弹窗: 先固化当前内容再开空白工作区,
        // 名称可事后在右键菜单 Rename 修改. 这样降低操作阻力, 与删除/重命名路径一致.
        var name = _("Workspace %d").printf (app_state.snapshots.size + 1);
        // 语义: 把"当前正在编辑的内容"固化进当前激活的工作区 (如 Workspace 1 = 目录A),
        // 再新建一个空白 Workspace 并激活它, 当前变为空白等待打开新目录.
        // 这样目录A 归属于原 Workspace, 新建的 Workspace 2 才是空白.
        push_undo_state ();
        // (1) 先把当前内容存回激活工作区
        sync_active_snapshot ();
        // (2) 清空当前状态 — 直接写 app_state 绕过 work_dir 属性 setter,
        //     避免 setter 的 sync_active_snapshot 把刚存好的目录A 覆盖成空.
        app_state.clear_items ();
        app_state.common_phrases.clear ();
        app_state.work_dir = null;
        // 直接写 app_state.work_dir 绕过了窗口 work_dir setter, 需手动同步
        // 依赖 work_dir 的 UI: 副标题 / 目录树 / 搜索框可见性 / 空状态.
        // 否则新空白工作区仍显示原目录路径与残留树结构.
        update_subtitle (_("No working directory set"));
        root_store.remove_all ();
        search_entry.visible = false;
        // (3) 此时当前为空, 新建快照捕获的即是空白 Workspace
        app_state.save_snapshot (name);
        active_workspace_index = app_state.snapshots.size - 1;
        refresh_list ();
        update_workdir_dependent_buttons ();
        update_empty_state ();
        // 先重建侧栏 (save_snapshot 已触发过一次重建, 这里确保 item 与索引一致),
        // 再设置高亮到新建的 Workspace, 否则重建会清空选中态.
        rebuild_snapshot_sidebar ();
        snapshot_sidebar.set_selected ((uint) active_workspace_index);
    }

    private void on_rename_snapshot () {
        // 捕获索引到局部变量: 对话框为异步回调, 期间 setup_menu(item=null) 可能
        // 把 snapshot_selected_index 重置为 -1, 直接读取会导致 rename 静默失效.
        var idx = snapshot_selected_index;
        if (idx < 0 || idx >= app_state.snapshots.size) return;
        var snap = app_state.snapshots.get (idx);
        var dialog = new Adw.AlertDialog (_("Rename Snapshot"), null);
        dialog.set_body (_("Enter a new name for this snapshot."));
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("rename", _("Rename"));
        dialog.set_response_appearance ("rename", Adw.ResponseAppearance.SUGGESTED);
        dialog.set_default_response ("rename");

        var entry = new Gtk.Entry ();
        entry.text = snap.name;
        entry.activate.connect (() => dialog.response ("rename"));
        dialog.set_extra_child (entry);
        dialog.response.connect ((resp) => {
            if (resp == "rename") {
                var name = entry.text.strip ();
                if (name.length > 0) {
                    app_state.rename_snapshot (idx, name);
                    // rename_snapshot 触发 snapshots_changed → rebuild_snapshot_sidebar,
                    // 重建会清空选中态, 需重新高亮激活工作区, 否则侧栏无任何选中项.
                    snapshot_sidebar.set_selected ((uint) active_workspace_index);
                }
            }
            dialog.destroy ();
        });
        dialog.present (this);
    }

    private void on_delete_snapshot () {
        // 捕获索引到局部变量: 确认对话框为异步回调, 期间 setup_menu(item=null) 可能
        // 把 snapshot_selected_index 重置为 -1, 直接读取会让 remove_snapshot 静默
        // 失败 (表现为弹了 toast 但列表删不掉).
        var idx = snapshot_selected_index;
        if (idx < 0 || idx >= app_state.snapshots.size) return;
        // 至少保留一个工作区: 唯一工作区不允许删除, 否则侧栏会空置且若干
        // 依赖 active_workspace_index 的逻辑会越界.
        if (app_state.snapshots.size <= 1) {
            show_toast (_("At least one workspace must remain"));
            return;
        }
        var snap = app_state.snapshots.get (idx);
        var dialog = new Adw.AlertDialog (
            _("Delete Snapshot"),
            _("Delete snapshot \"%s\"? This cannot be undone.").printf (snap.name)
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("delete", _("Delete"));
        dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");
        dialog.response.connect ((resp) => {
            if (resp == "delete") {
                // 删除前, 把当前编辑内容存回激活工作区 (若它正是被删项, 则丢弃)
                if (idx != active_workspace_index) {
                    sync_active_snapshot ();
                }
                app_state.remove_snapshot (idx);
                // 修正激活索引: 删的是数组中部/末尾时, 后续项前移
                if (active_workspace_index > idx) {
                    active_workspace_index--;
                } else if (active_workspace_index == idx) {
                    active_workspace_index = app_state.snapshots.size > 0
                        ? int.min (active_workspace_index, app_state.snapshots.size - 1)
                        : -1;
                }
                snapshot_selected_index = -1;
                if (active_workspace_index >= 0) {
                    // 删除的若是激活工作区, 此处需把新激活工作区的快照应用到 AppState,
                    // 否则界面仍显示已删除工作区的内容, 后续 sync_active_snapshot 会把
                    // 该内容错误地写入新激活工作区 (覆盖其真实数据).
                    apply_active_snapshot_to_ui ();
                }
                show_toast (_("Workspace deleted"));
            }
            dialog.destroy ();
        });
        dialog.present (this);
    }

    // 精选的 Adwaita symbolic 图标, 供工作区图标选择使用 (取自系统自带图标主题,
    // 均已确认存在于 /usr/share/icons/Adwaita/symbolic 中).
    private static string[] SNAPSHOT_ICON_CHOICES = {
        "view-grid-symbolic",
        "folder-symbolic",
        "folder-documents-symbolic",
        "document-open-symbolic",
        "text-x-generic-symbolic",
        "x-office-document-symbolic",
        "image-x-generic-symbolic",
        "text-editor-symbolic",
        "document-edit-symbolic",
        "folder-open-symbolic",
        "view-list-symbolic",
        "system-file-manager-symbolic",
        "user-home-symbolic",
        "list-add-symbolic"
    };

    private void on_change_snapshot_icon () {
        // 捕获索引到局部变量: 图标选择对话框为异步回调, 期间 setup_menu(item=null)
        // 可能把 snapshot_selected_index 重置为 -1.
        var idx = snapshot_selected_index;
        if (idx < 0 || idx >= app_state.snapshots.size) return;
        var snap = app_state.snapshots.get (idx);
        var current_icon = snap.icon_name;

        var dialog = new Adw.Dialog ();
        dialog.title = _("Change Icon");
        dialog.set_content_width (440);
        // 高度跟随内容自适应 (AdwDialog:follows-content-size), 而非固定值.
        // 未使用 breakpoint, 故无需手动设最小尺寸.
        dialog.follows_content_size = true;

        // 垂直布局: 顶部 AdwHeaderBar + 下方图标网格.
        // 按 Adw.Dialog 标准用法, 置于其内的 AdwHeaderBar 会自动显示标题
        // 并附带系统关闭按钮 (无需手动添加), 关闭即 adw_dialog_close().
        var root_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        // follows_content_size 下宽高都跟随内容, 故用 width_request 锁死宽度,
        // 高度仍由内容自然决定 (自适应).
        root_box.width_request = 440;
        // 与标题栏 (AdwHeaderBar) 共用 background 配色, 避免内容区用 surface 色
        // 导致与标题栏出现背景色差 (卡片感).
        root_box.add_css_class ("background");
        var header = new Adw.HeaderBar ();
        // flat: 移除 HeaderBar 底部阴影/分隔线, 使标题栏与内容区背景连续,
        // 避免短内容下出现分割感 (与 Preferences 对话框一致的观感).
        header.add_css_class ("flat");
        root_box.append (header);

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.vexpand = true;
        scrolled.hexpand = true;
        scrolled.propagate_natural_height = true;
        scrolled.add_css_class ("background");

        // 用 Gtk.Grid 而非 FlowBox: FlowBox 的 homogeneous 仅保证列等宽,
        // 无法保证格子宽=高, 实际会变成长方形. Grid + 固定 64x64 按钮可得到
        // 严格的正方形格子.
        int target_index = idx;

        var grid = new Gtk.Grid ();
        grid.column_spacing = 12;
        grid.row_spacing = 12;
        grid.margin_start = 16;
        grid.margin_end = 16;
        grid.margin_top = 16;
        grid.margin_bottom = 16;
        grid.halign = Gtk.Align.CENTER;
        grid.valign = Gtk.Align.START;

        const int COLS = 5;
        int col = 0;
        int grow = 0;
        foreach (var icon in SNAPSHOT_ICON_CHOICES) {
            var img = new Gtk.Image ();
            img.icon_name = icon;
            img.pixel_size = 32;
            var btn = new Gtk.Button ();
            // 锁定正方形, 保证每个格子都是 64x64
            btn.width_request = 64;
            btn.height_request = 64;
            btn.child = img;
            btn.tooltip_text = icon;
            // 当前已选图标用有框样式标记
            btn.has_frame = (icon == current_icon);
            btn.halign = Gtk.Align.CENTER;
            btn.valign = Gtk.Align.CENTER;
            grid.attach (btn, col, grow, 1, 1);
            col++;
            if (col >= COLS) { col = 0; grow++; }
            btn.clicked.connect (() => {
                if (target_index < 0 || target_index >= app_state.snapshots.size) return;
                app_state.snapshots.get (target_index).icon_name = icon;
                rebuild_snapshot_sidebar ();
                snapshot_sidebar.set_selected ((uint) active_workspace_index);
                dialog.close ();
            });
        }

        scrolled.child = grid;
        root_box.append (scrolled);
        dialog.set_child (root_box);
        dialog.present (this);
    }

    private void on_snapshot_save_as () {
        // 捕获索引到局部变量: 文件对话框为异步回调, 期间 setup_menu(item=null)
        // 可能把 snapshot_selected_index 重置为 -1.
        var idx = snapshot_selected_index;
        if (idx < 0 || idx >= app_state.snapshots.size) return;
        var snap = app_state.snapshots.get (idx);
        var temp_state = new AppState ();
        snap.apply_to (temp_state);

        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Save Snapshot As Project");
        var filter_fcol = new Gtk.FileFilter ();
        filter_fcol.name = _("FileCollector Project (*.fcol)");
        filter_fcol.add_pattern ("*.fcol");
        var filters = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters.append (filter_fcol);
        dialog.set_filters (filters);
        dialog.set_default_filter (filter_fcol);
        if (work_dir != null) dialog.initial_folder = work_dir;
        dialog.set_initial_name ("%s.fcol".printf (snap.name.replace (" ", "_")));

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".fcol")) path += ".fcol";
                ProjectManager.write_project_file (
                    path, temp_state.work_dir, temp_state.use_absolute, temp_state.show_header,
                    temp_state.items, temp_state.check_model.checked_files,
                    temp_state.check_model.checked_dirs, temp_state.common_phrases,
                    new Gee.ArrayList<WorkspaceSnapshot> ()
                );
                show_toast (_("Saved: %s").printf (GLib.Path.get_basename (path)));
            } catch (Error e) {
                if (!(e is GLib.IOError.CANCELLED || e is Gtk.DialogError.DISMISSED)) {
                    show_error (_("Save Failed"), e.message);
                }
            }
        });
    }

    // 合并导出: 收集所有快照的 items, 生成一段合并文本 / ZIP, 不改变当前工作区.
    private void on_merge_export_snapshots () {
        if (app_state.snapshots.size == 0) {
            show_toast (_("No snapshots to merge"));
            return;
        }
        var merged = new Gee.ArrayList<ItemData> ();
        foreach (var snap in app_state.snapshots) {
            foreach (var it in snap.items) {
                merged.add (new ItemData (it.item_type, it.file_path, it.content, it.force_absolute, it.is_missing));
            }
        }
        if (merged.size == 0) {
            show_toast (_("Snapshots are empty, nothing to export"));
            return;
        }
        // 复用现有导出逻辑: 临时把合并结果交给导出对话框流程.
        export_items_to_clipboard (merged);
    }

    // 将给定 items 复制为合并文本到剪贴板 (供合并导出复用)
    private void export_items_to_clipboard (Gee.ArrayList<ItemData> export_items) {
        try {
            FileGenerator.generate_to_clipboard (export_items, use_absolute, show_header, work_dir, this.get_display ());
            show_toast (_("Merged %d items copied to clipboard").printf (export_items.size));
        } catch (Error e) {
            show_error (_("Merge Export Failed"), e.message);
        }
    }

    private void update_subtitle_from_state () {
        update_subtitle (work_dir != null ? work_dir.get_path () : _("No working directory set"));
    }

    private void refresh_directory_tree_if_needed () {
        if (work_dir == null) return;
        // 工作目录变更时重建目录树根; 否则维持现有树 (勾选状态由 check_model 驱动)
        // 为避免无谓重建, 仅在根不存在或路径不同时重建.
        if (root_store.get_n_items () == 0) {
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);
            load_directory_children_lazy (root_item);
        }
    }

    public CliController create_cli_from_state () {
        var cli = new CliController ();
        cli.initialize_from_app_state (app_state);
        return cli;
    }

    public void apply_cli_operations (CliController cli) {
        push_undo_state ();
        bool work_dir_changed = cli.apply_to_state (app_state);

        if (work_dir_changed) {
            update_subtitle (work_dir.get_path ());
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);
            load_directory_children_lazy (root_item);
            GLib.Idle.add (() => {
                var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
                if (root_row != null) {
                    root_row.set_expanded (true);
                }
                return Source.REMOVE;
            });
            search_entry.visible = true;
        } else if (work_dir != null && root_store.get_n_items () > 0) {
            foreach (var path in check_model.checked_files) {
                ensure_path_loaded (path);
            }
            refresh_all_tree_states ();
        }

        refresh_list ();
        update_workdir_dependent_buttons ();
        update_empty_state ();

        if (cli.operation_messages.size > 0) {
            var messages = new Gee.ArrayList<string> ();
            for (int i = 0; i < cli.operation_messages.size; i++) {
                messages.add (cli.operation_messages.get (i));
            }
            GLib.Idle.add (() => {
                // HIG: 批量操作合并为一条汇总通知, 逐条弹 Toast 会形成通知轰炸
                var toast = new Adw.Toast (string.joinv (" · ", messages.to_array ()));
                toast.timeout = 3;
                toast_overlay.add_toast (toast);
                return Source.REMOVE;
            });
        }
    }

    public void initialize_from_cli (CliController cli) {
        apply_cli_operations (cli);
    }

    // ─── Tree View ───────────────────────────────────────────────────────

    private void remove_items_by_path (string path) {
        UIHelpers.remove_items_by_path (items, path);
    }

    private bool path_in_items (string path) {
        return UIHelpers.path_in_items (items, path);
    }

    private ItemData? find_item_by_path (string path) {
        return UIHelpers.find_item_by_path (items, path);
    }

    private async void on_open_folder_clicked () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Select Working Folder");
        try {
            var folder = yield dialog.select_folder (this, null);
            if (folder == null) return;

            if (app_state.window_closing) return;

            this.work_dir = folder;

            update_subtitle (folder.get_path ());

            root_store.remove_all ();
            check_model.clear ();
            items.clear ();
            undo_manager.clear ();
            update_action_sensitivity ();
            update_workdir_dependent_buttons ();

            var root_item = new DirectoryItem (folder.get_basename (), folder.get_path (), true);
            root_store.append (root_item);

            load_directory_children_lazy (root_item);
            search_entry.visible = true;

            var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
            if (root_row != null) {
                root_row.set_expanded (true);
            }

            GLib.Idle.add (() => {
                if (app_state.window_closing) return Source.REMOVE;
                refresh_list ();
                git_panel.on_work_dir_changed ();
                return Source.REMOVE;
            });
        } catch (Error e) {
            warning ("文件夹选择失败: %s", e.message);
        }
    }

    // 后台线程: 枚举单个目录的子条目
    private static Gee.ArrayList<DirChildInfo> enumerate_dir_children (string dir_path, GLib.Cancellable? cancellable = null) {
        return UIHelpers.enumerate_dir_children (dir_path, cancellable);
    }

    // 同步版本: 直接在调用线程加载子节点 (用于需要立即获取结果的场景, 如 ensure_path_loaded)
    private void load_directory_children_sync (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;
        var entries = enumerate_dir_children (parent_item.path);
        for (int i = 0; i < entries.size; i++) {
            var e = entries.get (i);
            parent_item.children.append (new DirectoryItem (e.name, e.path, e.is_dir));
        }
        refresh_subtree_states (parent_item);
        parent_item.children_loaded = true; // 强制标记已尝试加载, 防止 ensure_path_loaded 无限重试
    }

    // 异步版本: 后台线程枚举目录, 完成后通过 Idle 批量更新 UI, 避免阻塞主线程
    private void load_directory_children_lazy (DirectoryItem parent_item) {
        if (!parent_item.is_dir) return;
        if (parent_item.children_loading) return;
        if (app_state.window_closing) return;
        parent_item.children_loading = true;
        string dir_path = parent_item.path;
        var cancellable = app_state.app_cancellable;
        try {
            GLib.Thread<void*>? thread = null;
            thread = new Thread<void*> ("load-dir-children", () => {
                var entries = enumerate_dir_children (dir_path, cancellable);
                // 分批流式插入 (Idle 回调在主线程执行, 防止大项目卡死 UI)
                apply_directory_children_lazy (parent_item, entries, thread);
                return null;
            });
            app_state.bg_threads.add (thread);
        } catch (ThreadError e) {
            parent_item.children_loading = false;
            warning ("Failed to create load-dir-children thread: %s", e.message);
            load_directory_children_sync (parent_item);
        }
    }

    // 分批流式插入子节点 (每帧 100 个), 防止加载大项目时卡死 UI.
    // 在主线程通过 Idle 分批执行; 完成后刷新子树状态并清理后台线程引用.
    // 边界检查确保父容器没有在中途被销毁.
    private void apply_directory_children_lazy (DirectoryItem parent,
                                                 Gee.ArrayList<DirChildInfo> children,
                                                 GLib.Thread<void*>? thread = null) {
        int total_items = (int) children.size;
        int chunk_size = 100;
        int current_offset = 0;

        // 显示进度条
        if (total_items > chunk_size) {
            Idle.add (() => {
                dir_load_label.set_text (_("Loading %d items...").printf (total_items));
                dir_load_progress.set_fraction (0);
                dir_load_revealer.reveal_child = true;
                return Source.REMOVE;
            });
        }

        GLib.Idle.add (() => {
            if (app_state.window_closing) {
                return GLib.Source.REMOVE;
            }
            if (parent == null || parent.children == null) {
                dir_load_revealer.reveal_child = false;
                return GLib.Source.REMOVE;
            }

            int limit = int.min (current_offset + chunk_size, total_items);
            for (int i = current_offset; i < limit; i++) {
                var child_info = children.get (i);
                var child_item = new DirectoryItem (child_info.name, child_info.path, child_info.is_dir);
                parent.children.append (child_item);
            }

            current_offset = limit;

            // 更新进度
            if (total_items > chunk_size) {
                double frac = (double) current_offset / total_items;
                dir_load_progress.set_fraction (frac);
                dir_load_label.set_text (_("Loaded %d / %d").printf (current_offset, total_items));
            }

            if (current_offset < total_items) {
                return GLib.Source.CONTINUE;
            }

            // 加载完毕: 隐藏进度条
            dir_load_revealer.reveal_child = false;
            parent.children_loading = false;
            parent.children_loaded = true;
            refresh_all_tree_states ();
            dir_column_view.queue_draw ();
            if (thread != null) app_state.bg_threads.remove (thread);
            return GLib.Source.REMOVE;
        });
    }

    // AI 工具入口: 设置某个文件路径的勾选状态
    private void set_tree_item_check (string abs_path, bool checked) {
        // 1. 更新 check_model (单一真相源)
        if (checked) {
            check_model.add_files ({ abs_path });
            if (!path_in_items (abs_path)) {
                var new_item = new ItemData ("file", abs_path, null, false);
                items.add (new_item);
                if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                    enqueue_item_for_preprocess (new_item);
                }
            }
        } else {
            check_model.remove_files ({ abs_path });
            remove_items_by_path (abs_path);
        }

        // 2. 触发懒加载, 确保该路径的父目录已加载 (这样 UI 才能显示)
        ensure_path_loaded (abs_path);

        // 3. 增量刷新该文件路径向上的三态 (与文件勾选等价)
        refresh_tree_state_for_path_str (abs_path);
        refresh_list ();
    }

    // 确保指定文件路径的所有父目录都已加载到树中
    private void ensure_path_loaded (string abs_path) {
        if (work_dir == null || !abs_path.has_prefix (work_dir.get_path () + "/")) return;
        if (root_store.get_n_items () == 0) return;
        ensure_path_token++;
        uint my_token = ensure_path_token;

        string rel = abs_path.substring (work_dir.get_path ().length + 1);
        string[] parts = rel.split ("/");
        var current = (DirectoryItem) root_store.get_item (0);

        for (int p = 0; p < parts.length - 1; p++) {
            bool found = false;
            for (uint c = 0; c < current.children.get_n_items (); c++) {
                var child = (DirectoryItem) current.children.get_item (c);
                if (child.name == parts[p]) {
                    current = child;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (current.children_loaded) return;
                load_directory_children_lazy (current);
                schedule_ensure_path_retry (abs_path, my_token);
                return;
            }
        }

        bool target_found = false;
        for (uint c = 0; c < current.children.get_n_items (); c++) {
            var child = (DirectoryItem) current.children.get_item (c);
            if (child.path == abs_path) {
                target_found = true;
                break;
            }
        }
        if (!target_found) {
            if (current.children_loaded) return;
            load_directory_children_lazy (current);
        }
    }

    private void schedule_ensure_path_retry (string abs_path, uint token) {
        GLib.Timeout.add (50, () => {
            if (app_state.window_closing || token != ensure_path_token) {
                return Source.REMOVE;
            }
            ensure_path_loaded (abs_path);
            return Source.REMOVE;
        });
    }

    // ─── Queue List ──────────────────────────────────────────────────────

    // 合并刷新: 把短时间内多次 refresh_list 调用 (如批量 VLM 完成, 或一次性导入数百文件)
    // 折叠为一次, 避免每次都做 O(n) 差分扫描与预览级联. 仅在时间窗口内首次调用时登记
    // 一个超时回调, 后续调用仅刷新"待执行"标记.
    private uint refresh_merge_source = 0;
    private void schedule_refresh_list () {
        if (refresh_merge_source != 0) return; // 已登记, 等待窗口内合并
        refresh_merge_source = GLib.Timeout.add (150, () => {
            refresh_merge_source = 0;
            refresh_list ();
            return Source.REMOVE;
        });
    }

    private void refresh_list () {
        // 防御: 在 splice/unselect/select 期间, selection 模型可能处于不稳定状态,
        // 嵌套调用时只由最外层管理深度计数, 避免信号处理函数重入导致崩溃.
        queue_update_depth++;
        try {
            // 1. 记录当前选中的 ItemData 对象引用
            var selected_items = new Gee.ArrayList<ItemData> ();
            // 关键修复: 避免 get_selection() (VAPI 所有权错误导致误 unref),
            // 改用 is_selected() 逐行判断选中状态.
            for (uint i = 0; i < queue_store.get_n_items (); i++) {
                if (queue_selection.is_selected (i)) {
                    selected_items.add ((ItemData) queue_store.get_item (i));
                }
            }

            uint n = queue_store.get_n_items ();
            int m = items.size;

            // 差分同步: 只替换发生变化的段, 避免全量重建
            // 2. 寻找第一个不一致的索引
            int first_diff = -1;
            int min_len = (int) uint.min (n, (uint) m);
            for (int i = 0; i < min_len; i++) {
                if (queue_store.get_item (i) != items.get (i)) {
                    first_diff = i;
                    break;
                }
            }

            // 3. 根据差异类型执行最小化 splice
            if (first_diff == -1) {
                if (n == m) {
                    // 完全一致，无需任何操作
                } else if (n < m) {
                    // 仅尾部追加
                    for (int i = (int)n; i < m; i++) {
                        queue_store.append (items.get (i));
                    }
                } else {
                    // 仅尾部删除
                    queue_store.splice (m, n - m, new GLib.Object[0]);
                }
            } else {
                // 4. 存在中间差异，寻找最后一个不一致的索引
                int last_diff_old = (int)n - 1;
                int last_diff_new = m - 1;
                while (last_diff_old >= first_diff && last_diff_new >= first_diff) {
                    if (queue_store.get_item (last_diff_old) == items.get (last_diff_new)) {
                        last_diff_old--;
                        last_diff_new--;
                    } else {
                        break;
                    }
                }

                int replace_len_old = last_diff_old - first_diff + 1;
                int replace_len_new = last_diff_new - first_diff + 1;

                GLib.Object[] adds = new GLib.Object[replace_len_new];
                for (int i = 0; i < replace_len_new; i++) {
                    adds[i] = items.get (first_diff + i);
                }
                // 仅替换发生变化的中间段
                queue_store.splice (first_diff, replace_len_old, adds);
            }

            // 5. 恢复选择状态 (基于对象引用)
            queue_selection.unselect_all ();
            bool any_selected = false;
            foreach (var sel_item in selected_items) {
                int idx = find_item_index (sel_item);
                if (idx >= 0) {
                    queue_selection.select_item (idx, false);
                    any_selected = true;
                }
            }
            if (!any_selected && items.size > 0) {
                queue_selection.select_item (0, false);
            }

            update_queue_buttons ();

            // 6. 更新预览面板: 仅在"选中项集合相对上次预览确实变化"时才重跑预览,
            // 避免一次列表变更 (拖拽/添加/删除经 items_changed) 级联触发无谓的重载与闪烁.
            var new_indices = get_selected_indices ();
            bool selection_unchanged = (last_previewed_selection != null
                && last_previewed_selection.size == new_indices.size);
            if (selection_unchanged) {
                for (int i = 0; i < new_indices.size; i++) {
                    if (last_previewed_selection.get (i) != new_indices.get (i)) {
                        selection_unchanged = false;
                        break;
                    }
                }
            }
            if (!selection_unchanged) {
                last_previewed_selection = new_indices;
                if (new_indices.size == 1) {
                    int sel = new_indices.get (0);
                    if (sel >= 0 && sel < items.size) {
                        update_preview (items.get (sel));
                    }
                } else if (new_indices.size > 1) {
                    show_multi_selection_preview (new_indices.size);
                } else {
                    clear_preview ();
                }
            }
        } finally {
            queue_update_depth--;
            if (queue_update_depth < 0) queue_update_depth = 0;
        }

        // 模型已恢复稳定, 统一触发一次 UI 刷新 (包括清除目录树选择等副作用).
        on_queue_selection_changed (0, 0);

        // 编排列表空状态切换: 无项显示 StatusPage 空状态页, 有项显示列表页
        if (items.size == 0) {
            queue_stack.visible_child = queue_empty_page;
        } else {
            queue_stack.visible_child_name = "list";
        }

        update_token_display ();
    }

    private Gee.ArrayList<int> get_selected_indices () {
        var indices = new Gee.ArrayList<int> ();
        // 关键修复: 避免 get_selection() (VAPI 所有权错误导致误 unref),
        // 改用 is_selected() 逐行收集选中索引. 同时防御模型未初始化/已释放.
        if (queue_selection == null) return indices;
        for (uint i = 0; i < queue_store.get_n_items (); i++) {
            if (queue_selection.is_selected (i)) {
                indices.add ((int) i);
            }
        }
        return indices;
    }

    private void show_multi_selection_preview (int count) {
        current_preview_item = null;
        preview_info_box.icon_name = "selection-mode-symbolic";
        preview_info_box.title = _("%d items selected").printf (count);
        preview_info_box.description = _("Select a single file to preview its content.");
        preview_stack.visible_child = preview_info_box;
    }

    // 切换预览时清空各面板内容. 注意: 不把代码视图缓冲置空、也不切到代码视图 —— 否则
    // GtkSource.View 会渲染出"行号 1 + 空白"的怪异空行, 在 Stack 的 crossfade 过渡中
    // 闪现. 代码视图缓冲交给 start_lazy_preview 在内容到达前清空, 或新内容的 set_text 整体覆盖.
    // 注意: preview_info_box 已是 Adw.StatusPage, 内容由 icon_name/title/description 属性
    // 驱动, 其内部子结构是 StatusPage 自管的 (ScrolledWindow>Viewport>Box), 切勿对它调
    // clear_container, 否则会 unparent 掉内部 viewport 导致整页变空白不显示.
    private void clear_preview_buffer () {
        UIHelpers.clear_container (preview_markdown_box);
    }

    private void clear_preview () {
        current_preview_item = null;
        clear_preview_buffer ();
        // 无选中项: 显示"未选择"占位, 而非空白的代码视图
        preview_info_box.icon_name = "text-x-generic-symbolic";
        preview_info_box.title = _("No file selected");
        preview_info_box.description = _("Select a file from the list or directory tree to preview it here.");
        preview_stack.visible_child = preview_info_box;
    }

    // 懒加载路径揭示内容: 把 stack 切到代码视图 (此前可能停在 markdown/info 页). 这是修复
    // "代码/纯文本类无法加载"的关键 —— 加载期间不切换 stack 页, 必须由内容到达时显式切回
    // preview_view, 否则内容写进了 preview_view 缓冲却不被显示.
    private void reveal_preview_view () {
        preview_stack.visible_child = preview_view;
    }

    private void update_queue_buttons () {
        var indices = get_selected_indices ();
        int count = indices.size;
        bool has_selection = count > 0;
        bool single = count == 1;
        bool has_items = items.size > 0;
        btn_add_text_above.sensitive = single;
        btn_add_text_below.sensitive = single;
        btn_move_up.sensitive = single && items.size > 1 && indices.get (0) > 0;
        btn_move_down.sensitive = single && items.size > 1 && indices.get (0) < items.size - 1;
        btn_delete.sensitive = has_selection;
        btn_clear.sensitive = has_items;
        btn_generate.sensitive = has_items;
        btn_ai_toc.sensitive = has_items;
        btn_git_delete.sensitive = has_selection;
        btn_git_clear.sensitive = has_items;

        update_action_sensitivity ();
    }

    private void update_workdir_dependent_buttons () {
        bool has_work_dir = work_dir != null;
        radio_relative_path.sensitive = has_work_dir;
        radio_absolute_path.sensitive = has_work_dir;
        check_write_header.sensitive = has_work_dir;

        // Git 相关按钮的可用性由面板自行管理 (取决于工作目录与 Git 模式)
        git_panel.refresh_sensitivity ();
        btn_toggle_git.sensitive = has_work_dir;
        btn_global_search.sensitive = has_work_dir;

        set_win_action_enabled ("global_search", has_work_dir);

        update_menu_action_sensitivity ();
    }

    private void update_menu_action_sensitivity () {
        bool has_work_dir = work_dir != null;
        var app = application;
        if (app == null) return;

        var save_action = app.lookup_action ("save_project") as SimpleAction;
        var save_as_action = app.lookup_action ("save_as_project") as SimpleAction;
        var clear_cache_action = app.lookup_action ("clear_cache") as SimpleAction;

        if (save_action != null) save_action.set_enabled (has_work_dir);
        if (save_as_action != null) save_as_action.set_enabled (has_work_dir);
        if (clear_cache_action != null) clear_cache_action.set_enabled (has_work_dir);
    }

    private void update_action_sensitivity () {
        var indices = get_selected_indices ();
        int count = indices.size;
        bool has_selection = count > 0;
        bool single = count == 1;
        bool has_items = items.size > 0;

        set_win_action_enabled ("generate", has_items);
        set_win_action_enabled ("generate_to_clipboard", has_items);
        set_win_action_enabled ("export_zip", has_items);
        set_win_action_enabled ("clear_items", has_items);
        set_win_action_enabled ("delete_item", has_selection);
        set_win_action_enabled ("move_up", single && has_items && indices.get (0) > 0);
        set_win_action_enabled ("move_down", single && has_items && indices.get (0) < items.size - 1);
        set_win_action_enabled ("insert_text", single);
        set_win_action_enabled ("insert_text_no_header", single);
        set_win_action_enabled ("undo", undo_manager.can_undo);
        set_win_action_enabled ("redo", undo_manager.can_redo);
    }

    private void set_win_action_enabled (string name, bool enabled) {
        var action = lookup_action (name) as SimpleAction;
        if (action != null) action.set_enabled (enabled);
    }

    private void on_add_external_files () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Select External Files");
        if (work_dir != null) dialog.initial_folder = work_dir;
        dialog.open_multiple.begin (this, null, (obj, res) => {
            try {
                var files = dialog.open_multiple.end (res);
                if (files.get_n_items () == 0) return;
                var to_add = new Gee.ArrayList<ItemData> ();
                int skipped = 0;
                for (uint i = 0; i < files.get_n_items (); i++) {
                    var file = (File) files.get_item (i);
                    var path = file.get_path ();
                    add_external_path_to_batch (path, to_add, ref skipped);
                }
                int added = commit_external_batch (to_add);
                if (added > 0) {
                    show_toast (_("Added %d external file(s)").printf (added));
                } else if (skipped > 0) {
                    show_toast (_("All %d file(s) already in list").printf (skipped));
                }
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                warning ("添加文件失败: %s", e.message);
            }
        });
    }

    // ─── 外部拖拽 / 添加 共用辅助 ───────────────────────────────────────
    // 把单个路径(文件或文件夹)展开为 ItemData 批次. 文件夹递归收集所有非忽略目录的
    // 文件, 跳过隐藏目录与配置中忽略的目录. 已在 items 中的路径计入 skipped,
    // 不会重复加入. 调用方负责 commit_external_batch 与 push_undo_state.
    private void add_external_path_to_batch (string path, Gee.ArrayList<ItemData> batch, ref int skipped) {
        // 文件夹: 递归收集, 复用 collect_files_recursive. 收集到的每个文件再走
        // 单文件入批逻辑, 共享去重.
        if (FileUtils.test (path, FileTest.IS_DIR)) {
            var collected = new Gee.ArrayList<string> ();
            collect_files_recursive (path, collected, null);
            foreach (var p in collected) {
                add_single_external_file_to_batch (p, batch, ref skipped);
            }
            return;
        }
        add_single_external_file_to_batch (path, batch, ref skipped);
    }

    private void add_single_external_file_to_batch (string path, Gee.ArrayList<ItemData> batch, ref int skipped) {
        if (path_in_items (path)) {
            skipped++;
            return;
        }
        // 仅当文件位于当前工作目录之外才标记为外部文件 (force_absolute=true,
        // 列表显示 [External file] + 强制绝对路径). 工作目录内的文件拖入应按常规项
        // 处理 (相对路径、无外部标记), 与从目录树勾选加入的行为一致.
        bool is_external = !is_path_inside_work_dir (path);
        batch.add (new ItemData ("file", path, null, is_external));
    }

    // 判断路径是否位于当前工作目录之内 (含子目录). work_dir 为 null 时一律视为外部.
    private bool is_path_inside_work_dir (string path) {
        if (work_dir == null) return false;
        return File.new_for_path (path).has_prefix (work_dir);
    }

    // 递归收集目录下所有非忽略 / 非隐藏目录中的文件路径. 与 SearchService /
    // AIController.list_files_recursive 保持一致的过滤口径.
    private void collect_files_recursive (string dir_path, Gee.ArrayList<string> collected, GLib.Cancellable? cancellable) {
        var dir = File.new_for_path (dir_path);
        if (!dir.query_exists ()) return;
        try {
            var en = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            string[] ignored = ConfigManager.get_ignored_dirs ();
            FileInfo info;
            while ((info = en.next_file ()) != null) {
                if (cancellable != null && cancellable.is_cancelled ()) return;
                string name = info.get_name ();
                var child = dir.get_child (name);
                if (info.get_file_type () == FileType.DIRECTORY) {
                    if (name in ignored || name.has_prefix (".")) continue;
                    collect_files_recursive (child.get_path (), collected, cancellable);
                } else {
                    collected.add (child.get_path ());
                }
            }
        } catch (Error e) {
            warning ("Failed to enumerate %s: %s", dir_path, e.message);
        }
    }

    // 把批次原子地写入 items: push_undo_state 一次, 批量 add + 触发二进制预处理,
    // 最后 refresh_list. 返回实际加入的数量. 空批次直接返回 0, 不污染 undo 栈.
    private int commit_external_batch (Gee.ArrayList<ItemData> batch) {
        if (batch.size == 0) return 0;
        push_undo_state ();
        // 工作目录内的拖入文件需同步勾选状态到目录树, 与从树勾选加入的行为一致
        // (常规勾选会 toggle_file + 加 items; 外部拖入已加 items, 这里补 check_model).
        var in_tree_paths = new Gee.ArrayList<string> ();
        int added = 0;
        foreach (var item in batch) {
            items.add (item);
            if (item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                enqueue_item_for_preprocess (item);
            }
            // force_absolute=false 表示文件位于工作目录内, 应勾选对应树节点
            if (!item.force_absolute && item.item_type == "file" && item.file_path != null) {
                if (!(item.file_path in check_model.checked_files)) {
                    in_tree_paths.add (item.file_path);
                }
            }
            added++;
        }
        if (in_tree_paths.size > 0) {
            check_model.add_files ((string[]) in_tree_paths.to_array ());
            // 增量刷新受影响的树节点: 按父目录去重, 逐个刷新 (向上覆盖整条祖先链),
            // 避免对大量文件逐一遍历祖先造成重复开销.
            var parent_dirs = new Gee.HashSet<string> ();
            foreach (var p in in_tree_paths) {
                var parent = File.new_for_path (p).get_parent ();
                if (parent != null) parent_dirs.add (parent.get_path ());
            }
            foreach (var d in parent_dirs) {
                refresh_tree_state_for_path_str (d);
            }
            dir_column_view.queue_draw ();
        }
        refresh_list ();
        return added;
    }

    private void insert_text (bool above, string? existing_text = null, owned ItemData? edit_data = null) {
        var dialog = new Adw.Dialog ();
        dialog.set_title (edit_data != null ? _("Edit Text") : _("Insert Custom Text"));
        dialog.set_content_width (450);
        dialog.set_content_height (350);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (dialog.title, ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("Cancel"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("OK"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var phrases_btn = new Gtk.Button ();
        phrases_btn.set_label (_("Common Phrases"));
        header_bar.pack_end (phrases_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("card");
        frame.add_css_class ("ai-input-frame");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);

        if (existing_text != null) {
            text_view.get_buffer ().set_text (existing_text, -1);
        }

        scrolled.set_child (text_view);
        frame.set_child (scrolled);
        content.append (frame);

        toolbar_view.set_content (content);

        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });

        ok_btn.clicked.connect (() => {
            var buffer = text_view.get_buffer ();
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            var text = buffer.get_text (start, end, false);
            if (text != null && text.strip () != "") {
                if (edit_data != null) {
                    // Bug #12 修复: 编辑文本项时记录 undo delta
                    int edit_index = find_item_index (edit_data);
                    string old_content = edit_data.content;
                    edit_data.content = text;
                    if (edit_index >= 0) {
                        push_undo_delta (new UndoDelta.for_edit (edit_index, old_content, text));
                    }
                    edit_data.update_token_stats ();
                    refresh_list ();
                    update_preview (edit_data);
                } else {
                    do_insert_text (text, above);
                }
            }
            dialog.close ();
        });

        if (edit_data != null) {
            phrases_btn.visible = false;
        } else {
            phrases_btn.clicked.connect (() => {
                dialog.close ();
                get_phrases_picker ().show_picker (above);
            });
        }

        dialog.present (this);
    }

    private void do_insert_text (string text, bool above) {
        var indices = get_selected_indices ();
        int current = indices.size == 1 ? indices.get (0) : -1;
        int index;
        if (current < 0) {
            index = above ? 0 : (int) items.size;
        } else {
            index = above ? current : current + 1;
        }
        var inserted = new Gee.ArrayList<ItemData> ();
        var item = new ItemData ("text", null, text, false);
        items.insert (index, item);
        inserted.add (item);
        push_undo_delta (new UndoDelta.for_insert (index, inserted));
        refresh_list ();
    }

    private void on_move_up () {
        var indices = get_selected_indices ();
        if (indices.size != 1) return;
        int index = indices.get (0);
        if (index <= 0) return;
        var tmp = items.get (index);
        items.set (index, items.get (index - 1));
        items.set (index - 1, tmp);
        push_undo_delta (new UndoDelta.for_swap (index - 1, index));
        refresh_list ();
        select_queue_row (index - 1);
    }

    private void on_move_down () {
        var indices = get_selected_indices ();
        if (indices.size != 1) return;
        int index = indices.get (0);
        if (index >= items.size - 1) return;
        var tmp = items.get (index);
        items.set (index, items.get (index + 1));
        items.set (index + 1, tmp);
        push_undo_delta (new UndoDelta.for_swap (index, index + 1));
        refresh_list ();
        select_queue_row (index + 1);
    }

    // 拖拽重排: 把 dragged 项移动到 target_row 之前或之后.
    // 索引约定与 UndoDelta.for_move(from, to) 一致 —— to 为元素移动后的"最终索引".
    // apply_redo_delta 对 MOVE 的实现即 remove(from) 后 insert(to), 故此处 perform 步骤与之相同.
    private void reorder_queue_item (ItemData dragged, int target_row, bool drop_after) {
        if (dragged == null) return;
        int from = find_item_index (dragged);
        if (from < 0) return;

        int to = target_row + (drop_after ? 1 : 0);
        // 移除 from 后, 高位索引整体下移 1, 需补偿
        if (to > from) to -= 1;
        if (to < 0) to = 0;
        if (to > items.size - 1) to = items.size - 1;
        if (from == to) return;

        var it = items.get (from);
        items.remove_at (from);
        items.insert (to, it);

        push_undo_delta (new UndoDelta.for_move (from, to));
        // items_changed 同时驱动 refresh_list (差分同步视图) 与 recovery_manager.schedule (落盘),
        // 比 on_move_up/down 仅 refresh_list 更完整地自动保存新顺序.
        app_state.items_changed ();
        select_queue_row (to);
    }

    // 拖拽落点指示线: 用单独的覆盖层 (drop_indicator) 精确画在相邻两行的边界上.
    // "悬停在上行下方" (after) 取本行底边, "悬停在下行上方" (before) 取本行顶边,
    // 二者 translate 到覆盖层后是同一条 y, 故指示线位置完全一致; 且不改变任何行布局
    // (覆盖层不参与列表排版), 列表不会因线出现而跳动. 替代 GTK 默认方角框.
    private void set_drop_indicator (Gtk.Widget? row, bool after) {
        if (row == null) {
            // 隐藏: 移除 .show 让 CSS opacity 过渡淡出 (覆盖层始终保留, 不拦截事件)
            drop_indicator.remove_css_class ("show");
            return;
        }
        // 边界点: after=本行底边, before=本行顶边
        double boundary_y = after ? (double) row.get_allocated_height () : 0;
        double ox, oy;
        if (row.translate_coordinates (queue_overlay, 0, boundary_y, out ox, out oy)) {
            drop_indicator.margin_top = (int) Math.round (oy) - 1;
            // 显示: 加 .show 触发 opacity 过渡淡入
            drop_indicator.add_css_class ("show");
        }
    }

    // 在 queue_list 坐标 (x, y) 处查找 queue-row-box.
    // 先用 pick() 精确定位; 若 pick() 返回非行 widget (行间缝隙),
    // 回退为遍历子 widget 找 y 坐标最近的行.
    private Gtk.Box? pick_row_box (double x, double y) {
        // 1. pick() 精确定位
        var picked = queue_list.pick (x, y, Gtk.PickFlags.DEFAULT);
        if (picked != null) {
            var w = picked;
            while (w != null && w != queue_list) {
                var b = w as Gtk.Box;
                if (b != null && b.has_css_class ("queue-row-box")) {
                    return b;
                }
                w = w.get_parent ();
            }
        }

        // 2. 回退: 遍历 queue_list 的直接子 widget (GtkListItemWidget),
        //    找 y 坐标最近的行 (处理行间缝隙盲区)
        Gtk.Box? best = null;
        double best_dist = double.MAX;
        var child = queue_list.get_first_child ();
        while (child != null) {
            double dummy_x = 0, top_y = 0;
            if (child.translate_coordinates (queue_list, 0, 0, out dummy_x, out top_y)) {
                double h = (double) child.get_height ();
                double bottom_y = top_y + h;
                double dist = (y < top_y) ? (top_y - y) : ((y > bottom_y) ? (y - bottom_y) : 0);
                if (dist < best_dist) {
                    var box = find_queue_row_box_in (child);
                    if (box != null) {
                        best = box;
                        best_dist = dist;
                    }
                }
            }
            child = child.get_next_sibling ();
        }
        return best;
    }

    // 在 widget 子树中递归查找带 queue-row-box CSS 类的 Box
    private Gtk.Box? find_queue_row_box_in (Gtk.Widget widget) {
        if (widget is Gtk.Box && widget.has_css_class ("queue-row-box")) {
            return widget as Gtk.Box;
        }
        var child = widget.get_first_child ();
        while (child != null) {
            var result = find_queue_row_box_in (child);
            if (result != null) return result;
            child = child.get_next_sibling ();
        }
        return null;
    }

    private void on_delete_item () {
        // 关键: 用 GLib.Idle.add 推迟 + 显式 ref. 这样:
        // 1. popover.closed 释放上游的 self ref 链 (避免 race)
        // 2. action 回调栈退栈后再跑删除
        // 3. 我们在 closure 内部显式 hold self, 即使外部 dispose 也安全
        GLib.Idle.add (() => {
            this.@ref ();
            try {
                perform_delete_sync ();
            } finally {
                this.@unref ();
            }
            return Source.REMOVE;
        });
    }

    private void perform_delete_sync () {
        // 防御: 整个删除流程 (unselect/remove/refresh_list) 期间屏蔽 selection 信号,
        // 避免在模型突变时重入 get_selection() 导致 GTK 断言失败.
        queue_update_depth++;
        try {
            var indices = get_selected_indices ();
            if (indices.size == 0) return;
            push_undo_state ();

            // 取消所有选中, 避免后续 refresh_list 走"还原选中"路径时
            // 持有即将被释放的 row 引用
            queue_selection.unselect_all ();

            var paths_to_uncheck = new Gee.ArrayList<string> ();
            for (int k = 0; k < indices.size; k++) {
                int idx = indices.get (k);
                if (idx < 0 || idx >= items.size) continue;
                var data = items.get (idx);
                if (data.item_type == "file" && !data.force_absolute && data.file_path != null) {
                    if (data.file_path in check_model.checked_files) {
                        paths_to_uncheck.add (data.file_path);
                    }
                }
            }

            if (paths_to_uncheck.size > 0) {
                check_model.remove_files ((string[]) paths_to_uncheck.to_array ());
            }

            int[] sorted = new int[indices.size];
            for (int k = 0; k < indices.size; k++) sorted[k] = indices.get (k);
            for (int i = 1; i < sorted.length; i++) {
                int v = sorted[i];
                int j = i - 1;
                while (j >= 0 && sorted[j] < v) {
                    sorted[j + 1] = sorted[j];
                    j--;
                }
                sorted[j + 1] = v;
            }
            foreach (int idx in sorted) {
                if (idx >= 0 && idx < items.size) {
                    items.remove_at (idx);
                }
            }

            refresh_all_tree_states ();
            refresh_list ();
        } finally {
            queue_update_depth--;
            if (queue_update_depth < 0) queue_update_depth = 0;
        }

        // refresh_list() 退出时已经把 queue_update_depth 归零并调用过
        // on_queue_selection_changed(), 这里不需要再触发一次.
    }

    private void on_clear_items () {
        if (items.size == 0) return;
        push_undo_state ();
        items.clear ();
        check_model.clear ();
        refresh_all_tree_states ();
        refresh_list ();
    }

    private void on_clear_items_with_confirm () {
        if (items.size == 0) return;

        var dialog = new Adw.AlertDialog (
            _("Confirm Clear"),
            _("Are you sure you want to clear all %d items from the queue?").printf (items.size)
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("clear", _("Clear"));
        dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");

        dialog.response.connect ((response) => {
            if (response == "clear") {
                on_clear_items ();
            }
            dialog.destroy ();
        });

        dialog.present (this);
    }

    private void select_queue_row (int index) {
        if (index >= 0 && index < items.size) {
            queue_selection.unselect_all ();
            queue_selection.select_item (index, false);
        }
    }

    private void on_queue_selection_changed (uint position, uint n_items) {
        // 防御: 模型正在突变时, selection 状态可能处于中间态,
        // 此时访问 queue_selection 可能触发 GTK 断言失败. 延迟到更新结束后再统一刷新 UI.
        if (queue_update_depth > 0) return;

        update_queue_buttons ();
        var indices = get_selected_indices ();
        if (indices.size == 1) {
            int sel = indices.get (0);
            if (sel >= 0 && sel < items.size) {
                update_preview (items.get (sel));
            }
            clear_tree_selection ();
        } else if (indices.size > 1) {
            show_multi_selection_preview (indices.size);
            clear_tree_selection ();
        } else {
            clear_preview ();
        }
    }

    private void on_queue_row_activated (uint position) {
        int index = (int)position;
        if (index < 0 || index >= items.size) return;
        var data = items.get (index);
        if (data.item_type == "text") {
            insert_text (false, data.content, data);
        }
    }

    private void update_preview (ItemData item) {
        // 去抖: 极短时间内对同一个文件重复发起预览 (例如一次操作经 refresh_list 级联
        // 多次触发), 直接忽略后续请求, 避免重复读取/重建导致的卡顿与闪烁.
        // 注意: 用户主动重新点击同一文件走的是 on_queue_selection_changed -> 此处,
        // 但重新点击不会在 80ms 内发生, 故正常重点击仍会执行 (且会回到顶部).
        int64 now_ms = (int64) (GLib.get_monotonic_time () / 1000);
        if (item == current_preview_item && now_ms - preview_last_request_ms < 80) {
            return;
        }
        preview_last_request_ms = now_ms;

        cancel_preview_loading ();
        // 同一帧内立即同步清空上一文件的全部内容, 消除"先闪现旧文件顶部再换文件"的窗口.
        clear_preview_buffer ();
        // 切换预览项时把滚动区归零到顶部: 代码与 Markdown 预览都经此入口,
        // 统一重置后可避免沿用上一文件 (尤其长文件) 的滚动位置, 使短文件停在空白区.
        preview_scrolled.get_vadjustment ().set_value (0);
        preview_auto_scroll = false;
        bool show_action_bar = false;
        current_preview_item = item;

        if (item.item_type == "file" && item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            btn_retry_preprocess.sensitive = true;
            switch (item.preprocess_status) {
                case PreprocessStatus.COMPLETED:
                    show_action_bar = true;
                    btn_retry_preprocess.tooltip_text = item.from_cache
                        ? _("Local cache loaded\nClick to force re-invoke VLM conversion")
                        : _("AI conversion complete\nClick to force re-invoke VLM conversion");
                    break;
                case PreprocessStatus.FAILED:
                    show_action_bar = true;
                    btn_retry_preprocess.tooltip_text = _("AI conversion failed\nClick to retry conversion");
                    break;
                case PreprocessStatus.PROCESSING:
                    btn_retry_preprocess.tooltip_text = _("Processing...");
                    btn_retry_preprocess.sensitive = false;
                    break;
                default:
                    btn_retry_preprocess.tooltip_text = _("Pending");
                    btn_retry_preprocess.sensitive = false;
                    break;
            }
        }

        preview_action_buttons.visible = show_action_bar;
        // 导出缓存按钮可用性: 仅当该项确有已落盘的完整缓存子文件夹时才可点击.
        bool exportable = show_action_bar && item.item_type == "file" && item.file_path != null
                          && work_dir != null;
        if (exportable) {
            var cache = new PreprocessCache (work_dir.get_path ());
            string hash = PreprocessCache.compute_file_hash (item.file_path);
            exportable = hash.length > 0 && cache.has_cache (hash);
        }
        btn_export_cache.sensitive = exportable;

        if (item.item_type == "text") {
            apply_preview_content_full (item, item.content.make_valid ());
        } else if (item.item_type == "file" && item.preprocess_status == PreprocessStatus.COMPLETED && item.preprocessed_content != null) {
            apply_preview_content_full (item, item.preprocessed_content.strip ());
        } else if (item.item_type == "file" && item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
            switch (item.preprocess_status) {
                case PreprocessStatus.PROCESSING:
                    apply_preview_content_full (item, _("Processing..."));
                    break;
                case PreprocessStatus.FAILED:
                    apply_preview_content_full (item, _("[AI conversion failed; click the retry button on the toolbar to reconvert]"));
                    break;
                case PreprocessStatus.CHECKING:
                    apply_preview_content_full (item, _("[Checking cache...]"));
                    break;
                case PreprocessStatus.PENDING:
                    apply_preview_content_full (item, _("[Preparing AI conversion...]"));
                    break;
                default:
                    apply_preview_content_full (item, _("[Binary file, preview unavailable]"));
                    break;
            }
        } else {
            try {
                var file = File.new_for_path (item.file_path);
                var info = file.query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                int64 file_size = info.get_size ();

                if (item.is_snippet ()) {
                    load_snippet_preview (item, file_size);
                } else if (is_markdown_path (item.file_path)) {
                    load_full_text_preview (item, true);
                } else {
                    start_lazy_preview (item, file_size);
                }
            } catch (Error e) {
                apply_preview_content_full (item, _("[Read error: %s]").printf (e.message));
            }
        }
    }

    private void apply_preview_content_full (ItemData item, string text) {
        bool use_markdown = item.item_type == "file"
            && (is_markdown_path (item.file_path)
                || (item.preprocess_status == PreprocessStatus.COMPLETED && item.preprocessed_content != null));

        if (use_markdown) {
            UIHelpers.clear_container (preview_markdown_box);
            preview_markdown_box.append (new MarkdownView (text));
            preview_stack.visible_child = preview_markdown_box;
        } else {
            apply_preview_with_highlight (text, item.file_path);
        }
    }

    // 后台线程全量读取文件字节 (主线程外执行, 避免大文件同步读阻塞 UI).
    // 读取前捕获代际, 读完后若代际已变化 (期间切换了预览) 则丢弃结果.
    private async uint8[]? read_entire_file_async (string path) {
        uint gen = preview_generation;
        uint8[] result = new uint8[0];
        try {
            FileInputStream? fis = File.new_for_path (path).read () as FileInputStream;
            if (fis == null) return null;
            uint8[] buffer = new uint8[PREVIEW_CHUNK_SIZE];
            ssize_t n;
            while ((n = fis.read (buffer)) > 0) {
                uint8[] copy = new uint8[n];
                Memory.copy (copy, buffer, n);
                // 累加到增长数组: 复制旧内容 + 新块
                uint8[] merged = new uint8[result.length + n];
                if (result.length > 0) Memory.copy (merged, result, result.length);
                Memory.copy (merged[result.length:merged.length], copy, n);
                result = merged;
            }
            fis.close ();
        } catch (Error e) {
            debug ("Async file read error: %s", e.message);
            return null;
        }
        if (gen != preview_generation) return null;
        return result;
    }

    // 获取 item 对应文本的 Markdown 渲染视图. 同一文件 (路径 + mtime 不变) 复用缓存的
    // widget 树, 避免重复解析 AST 与重建子 widget. 长文档 (>阈值) 的构建延迟到空闲回调,
    // 先返回占位 label, 构建完成后原地替换, 防止切换时被同步构建阻塞.
    private Gtk.Widget get_markdown_view (ItemData item, string text) {
        string key;
        if (item.item_type == "file") {
            int64 mtime = 0;
            try {
                var info = File.new_for_path (item.file_path).query_info (
                    FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                mtime = (int64) info.get_modification_time ().tv_sec;
            } catch (Error e) {}
            key = "f:" + item.file_path + "@" + mtime.to_string ();
        } else {
            // 内存内容 (如 AI 预处理结果): 用长度 + 内容前 256 字节做廉价指纹
            key = "m:" + text.length.to_string () + ":" + text.substring (0, int.min (256, text.length));
        }

        if (markdown_cache_key == key && markdown_cache_view != null) {
            return markdown_cache_view;
        }

        // 大文档延迟构建: 返回占位, 空闲时构建并替换
        if (text.length > (int) MARKDOWN_DEFER_THRESHOLD) {
            var placeholder = new Gtk.Label (_("Rendering Markdown…")) { hexpand = true, vexpand = true };
            placeholder.add_css_class ("dim-label");
            placeholder.valign = Gtk.Align.CENTER;
            var holder = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            holder.append (placeholder);
            GLib.Idle.add (() => {
                if (markdown_cache_key == key) return Source.REMOVE; // 已被新预览取代
                var built = new MarkdownView (text);
                markdown_cache_view = built;
                markdown_cache_key = key;
                // 替换占位 (仅当当前仍是本次预览)
                if (placeholder.get_parent () == holder) {
                    holder.remove (placeholder);
                    holder.append (built);
                }
                return Source.REMOVE;
            });
            return holder;
        }

        var view = new MarkdownView (text);
        markdown_cache_view = view;
        markdown_cache_key = key;
        return view;
    }

    private void load_full_text_preview (ItemData item, bool use_markdown) {
        // 改为后台线程读文件, 主线程仅在读取完成后渲染, 避免大文件同步读卡顿 UI.
        read_entire_file_async.begin (item.file_path, (obj, res) => {
            uint8[]? buf = read_entire_file_async.end (res);
            if (buf == null) {
                apply_preview_with_highlight (_("[Read error]"), item.file_path);
                return;
            }
            // 代际已变 (切换了预览) 或 buffer 已被新内容接管, 直接丢弃
            string text = EncodingHelper.decode_to_utf8 (buf);
            if (use_markdown) {
                var md = get_markdown_view (item, text);
                UIHelpers.clear_container (preview_markdown_box);
                preview_markdown_box.append (md);
                preview_stack.visible_child = preview_markdown_box;
            } else {
                apply_preview_with_highlight (text, item.file_path);
            }
        });
    }

    private void load_snippet_preview (ItemData item, int64 file_size) {
        // 后台线程读文件, 主线程切片高亮. 仅读取到 end_line 为止以约束内存/IO:
        // 在线程内逐字节扫描换行, 数到 end_line 后停止.
        uint gen = preview_generation;
        string path = item.file_path;
        int end_line = item.end_line;
        read_line_range_async.begin (path, end_line, (obj, res) => {
            uint8[]? buf = read_line_range_async.end (res);
            if (buf == null) {
                apply_preview_with_highlight (_("[Read error]"), item.file_path);
                return;
            }
            if (gen != preview_generation) return;
            string text = EncodingHelper.decode_to_utf8 (buf);
            string snippet = extract_line_range (text, item.start_line, item.end_line);
            apply_preview_with_highlight (snippet, item.file_path);
        });
    }

    // 后台读取文件, 但只读到约 end_line 行处即停止 (按换行计数), 约束大文件的读取量.
    private async uint8[]? read_line_range_async (string path, int end_line) {
        uint gen = preview_generation;
        uint8[] result = new uint8[0];
        try {
            FileInputStream? fis = File.new_for_path (path).read () as FileInputStream;
            if (fis == null) return null;
            int nl_count = 0;
            uint8[] buffer = new uint8[PREVIEW_CHUNK_SIZE];
            ssize_t n;
            while ((n = fis.read (buffer)) > 0) {
                for (ssize_t i = 0; i < n; i++) {
                    if (buffer[i] == 0x0A) nl_count++;
                }
                uint8[] copy = new uint8[n];
                Memory.copy (copy, buffer, n);
                uint8[] merged = new uint8[result.length + n];
                if (result.length > 0) Memory.copy (merged, result, result.length);
                Memory.copy (merged[result.length:merged.length], copy, n);
                result = merged;
                // 读到 end_line 之后若干行即可停止 (多留 2 行余量, 避免截断 end_line)
                if (nl_count >= end_line + 2) break;
            }
            fis.close ();
        } catch (Error e) {
            debug ("Async line-range read error: %s", e.message);
            return null;
        }
        if (gen != preview_generation) return null;
        return result;
    }

    private void cancel_preview_loading () {
        preview_fully_loaded = true;
        // 使任何仍在飞行中的旧预览线程失效, 防止其后续把过期内容写入缓冲区
        preview_generation++;
        if (preview_fis != null) {
            try { preview_fis.close (); } catch (Error e) {}
            preview_fis = null;
        }
        // 复位读取锁, 允许新的懒加载重新发起读取 (否则旧读仍占锁会导致新读直接 return)
        preview_loading = false;
        preview_leftover = new uint8[0];
        preview_current_path = null;
    }

    private void start_lazy_preview (ItemData item, int64 file_size) {
        // 先作废任何进行中的旧懒加载 (复位读取锁与代际), 再发起本次读取,
        // 避免快速重复触发时旧读占锁/代际失效, 导致真实内容永远不被写入缓冲区.
        cancel_preview_loading ();

        // 加载期间不显示任何加载指示; 内容到达直接呈现. 此处在内容到达前清空缓冲区,
        // 否则后续 append_to_preview 会把新内容拼到旧内容之后. (清空发生在 preview_view
        // 可见之前, 不会出现"行号1空行"的闪现.)
        (preview_view.get_buffer () as GtkSource.Buffer).set_text ("", -1);
        preview_view.set_show_line_numbers (true);

        // 新预览代际: 让此前可能仍在飞行的线程 (同一文件、偏移 0 重读) 失效
        preview_generation++;
        preview_file_size = file_size;
        preview_loaded_bytes = 0;
        preview_leftover = new uint8[0];
        preview_fully_loaded = false;
        preview_loading = false;
        preview_current_path = item.file_path;
        // 切换文件时预览停在顶部 (不再自动跟随加载到底), 由下方 set_show_line_numbers
        // 与 apply_preview_with_highlight 内的滚动归零共同保证回到开头、无残留空白.
        preview_auto_scroll = false;

        try {
            // 用 BufferedInputStream 包裹底层的 FileInputStream: 单次 read() 会先在进程内
            // 缓冲区填满 PREVIEW_CHUNK_SIZE, 再拷出; 配合增大的块大小, 大文件分块读取的
            // 系统调用 / 线程往返次数显著下降 (原 64KB 直读对每个块都直接落系统调用).
            var raw = File.new_for_path (item.file_path).read ();
            preview_fis = new BufferedInputStream (raw);
            ((BufferedInputStream) preview_fis).buffer_size = (uint) PREVIEW_CHUNK_SIZE;
            load_preview_chunk.begin ();
        } catch (Error e) {
            var buffer = preview_view.get_buffer () as GtkSource.Buffer;
            buffer.set_text (_("[Read error: %s]").printf (e.message), -1);
        }
    }

    private async void load_preview_chunk () {
        if (preview_loading || preview_fully_loaded || preview_fis == null) return;
        preview_loading = true;

        // 捕获本线程所属的代际; 若此后用户切换/移动触发了新一代预览, 本线程恢复时
        // 其捕获值与 preview_generation 不一致, 则丢弃本次读到的内容, 不写入缓冲区.
        uint gen = preview_generation;
        string? target_path = preview_current_path;
        // 先把当前流捕获到局部变量: cancel_preview_loading() 会在用户切换预览/关闭
        // 窗口时关闭并置空 preview_fis 字段, 若后台线程仍引用该字段就会对 null 调用
        // read() 触发 "g_input_stream_read: assertion 'G_IS_INPUT_STREAM (stream)' failed".
        // 改为引用局部副本后, 即使字段被置空, 线程读到的仍是有效的 (可能已关闭的) 流对象,
        // 读取已关闭流只会抛出可被下方 try 捕获的错误, 而非断言失败.
        InputStream? fis = preview_fis;
        if (fis == null) {
            preview_loading = false;
            return;
        }
        uint8[]? new_data = null;
        bool read_done = false;

        try {
            new Thread<void*> ("preview-read", () => {
                try {
                    uint8[] buffer = new uint8[PREVIEW_CHUNK_SIZE];
                    ssize_t n = fis.read (buffer);
                    if (n > 0) {
                        new_data = buffer[0:n];
                    }
                } catch (Error e) {
                    debug ("Preview read error: %s", e.message);
                }
                read_done = true;
                Idle.add (() => {
                    load_preview_chunk.callback ();
                    return Source.REMOVE;
                });
                return null;
            });
            yield;
        } catch (Error e) {
            debug ("Failed to create preview-read thread: %s", e.message);
            preview_loading = false;
            return;
        }

        if (target_path != preview_current_path) return;
        // 代际校验: 本线程已过期 (期间发生了新的预览请求), 丢弃其内容, 避免重复/错乱
        if (gen != preview_generation) {
            preview_loading = false;
            return;
        }

        if (new_data == null || new_data.length == 0) {
            preview_fully_loaded = true;
            preview_loading = false;
            if (preview_leftover.length > 0) {
                reveal_preview_view ();
                append_to_preview (EncodingHelper.decode_to_utf8 (preview_leftover));
                preview_leftover = new uint8[0];
            } else {
                // 空文件: 切到代码视图显示空内容
                reveal_preview_view ();
            }
            return;
        }

        preview_loaded_bytes += new_data.length;

        uint8[] combined = new uint8[preview_leftover.length + new_data.length];
        Memory.copy (combined, preview_leftover, preview_leftover.length);
        Memory.copy (combined[preview_leftover.length:combined.length], new_data, new_data.length);

        int last_nl = -1;
        for (int i = combined.length - 1; i >= 0; i--) {
            if (combined[i] == 0x0A) { last_nl = i; break; }
        }

        uint8[] to_decode;
        if (last_nl >= 0) {
            to_decode = combined[0:last_nl + 1];
            preview_leftover = combined[last_nl + 1:combined.length];
        } else {
            if (combined.length > 1048576) {
                to_decode = combined;
                preview_leftover = new uint8[0];
            } else {
                to_decode = new uint8[0];
                preview_leftover = combined;
            }
        }

        if (to_decode.length > 0) {
            // 首个分块到达: 切回代码视图. 此前 stack 可能停在 markdown/info 页 (加载期间
            // 未切换 stack 页), 必须显式切回 preview_view 内容才可见. 快速切换时若已在新文件
            // 加载态, 当前线程会因代际校验在上方 return, 不会误切走新文件的内容页.
            reveal_preview_view ();
            append_to_preview (EncodingHelper.decode_to_utf8 (to_decode));
        }

        if (preview_loaded_bytes >= preview_file_size) {
            preview_fully_loaded = true;
            if (preview_leftover.length > 0) {
                reveal_preview_view ();
                append_to_preview (EncodingHelper.decode_to_utf8 (preview_leftover));
                preview_leftover = new uint8[0];
            }
        }

        preview_loading = false;
    }

    private void append_to_preview (string text) {
        var buffer = preview_view.get_buffer () as GtkSource.Buffer;
        Gtk.TextIter end_iter;
        buffer.get_end_iter (out end_iter);
        buffer.insert (ref end_iter, text, -1);
        // 不在此处自动滚动: 切换文件时已通过 apply_preview_with_highlight 归零到顶部,
        // 增量加载时保持当前视口 (顶部), 由用户自行滚动, 避免短文件停在空白区.
    }

    // 按 1-based 行号范围从文本中提取对应行
    private static string extract_line_range (string text, int start_line, int end_line) {
        if (start_line < 1 || end_line < start_line) return text;
        string[] lines = text.split ("\n");
        int s = start_line - 1;
        int e = int.min (end_line, lines.length);
        if (s >= lines.length) return "";
        var sb = new StringBuilder ();
        for (int i = s; i < e; i++) {
            sb.append (lines[i]);
            sb.append_c ('\n');
        }
        return sb.str;
    }

    // 根据文件扩展名判断是否按 Markdown 渲染 (.md / .markdown),
    // 复用 AI 侧边栏的 MarkdownView (基于 cmark-gfm) 支持标题/列表/代码块/表格等.
    private static bool is_markdown_path (string? path) {
        if (path == null) return false;
        string lower = path.down ();
        return lower.has_suffix (".md") || lower.has_suffix (".markdown");
    }

    private void on_retry_preprocess (ItemData item) {
        if (item == null || item.item_type != "file" || !item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) return;
        if (item.preprocess_status == PreprocessStatus.PROCESSING) return;

        if (work_dir != null) {
            var cache = new PreprocessCache (work_dir.get_path ());
            cache.invalidate_cache (item.file_path);
        }

        item.preprocessed_content = null;
        item.from_cache = false;
        item.preprocess_status = PreprocessStatus.PENDING;

        refresh_list ();
        update_preview (item);
        enqueue_item_for_preprocess (item);
    }

    public void on_clear_cache () {
        if (work_dir == null) {
            show_toast (_("No working directory set yet"));
            return;
        }

        var dialog = new Adw.AlertDialog (
            _("Confirm Cache Deletion?"),
            _("This will delete the .filecollector_cache hidden folder under the working directory.\nNext time images/PDFs are processed, VLM will be re-invoked and consume API tokens.")
        );
        dialog.add_response ("cancel", _("Cancel"));
        dialog.add_response ("clear", _("Clear"));
        dialog.set_response_appearance ("clear", Adw.ResponseAppearance.DESTRUCTIVE);
        dialog.set_default_response ("cancel");

        dialog.response.connect ((resp) => {
            if (resp == "clear") {
                var cache = new PreprocessCache (work_dir.get_path ());
                cache.clear_all ();

                for (int i = 0; i < items.size; i++) {
                    var item = items.get (i);
                    if (item.item_type == "file" && item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        item.preprocess_status = PreprocessStatus.NONE;
                        item.preprocessed_content = null;
                        item.from_cache = false;
                    }
                }

                refresh_list ();
                var indices = get_selected_indices ();
                if (indices.size == 1) {
                    int sel = indices.get (0);
                    if (sel >= 0 && sel < items.size) {
                        update_preview (items.get (sel));
                    }
                }

                show_toast (_("Workspace cache cleared"));
            }
        });
        dialog.present (this);
    }

    // ─── 编排列表右键菜单 ───────────────────────────────────────────────────

    // 关键修复: ContextMenus.show_queue_menu 会把 delegate target 存为原始 gpointer
    // 并且不 ref. 如果传捕获 item/self 的 lambda, target 是临时的闭包数据,
    // 在 show_queue_context_menu 返回后就被释放, 导致点击菜单时 target 已成野指针
    // (g_object_ref 断言失败并 segfault). 因此把所有需要 item 的状态先存到 window
    // 字段, 再传实例方法 (target 固定为 window), 由 window 生命周期保证安全.
    private ItemData? ctx_item = null;
    private int ctx_index = -1;

    private void on_ctx_edit_text () {
        if (ctx_item != null) {
            insert_text (false, ctx_item.content, ctx_item);
        }
    }

    private void on_ctx_copy_path () {
        if (ctx_item == null || ctx_item.file_path == null) return;
        string path_to_copy = ctx_item.file_path;
        if (!ctx_item.force_absolute && work_dir != null && !use_absolute) {
            string wd = work_dir.get_path () + "/";
            if (path_to_copy.has_prefix (wd)) {
                path_to_copy = path_to_copy.substring (wd.length);
            }
        }
        get_clipboard ().set_text (path_to_copy);
    }

    private void on_ctx_show_folder () {
        if (ctx_item == null || ctx_item.file_path == null) return;
        show_file_in_folder (ctx_item.file_path);
    }

    private void on_ctx_refresh_list () {
        refresh_list ();
    }

    private void on_ctx_push_undo () {
        push_undo_state ();
    }

    private void on_ctx_retry_preprocess (ItemData it) {
        on_retry_preprocess (it);
    }

    private void on_ctx_export_cache (ItemData it) {
        export_item_cache (it);
    }

    // 判断某 ItemData 是否可导出缓存: 需为文件、有源路径、处于 work_dir 下, 且对应的
    // 完整缓存子文件夹 ({hash}/ md + imgs) 已落盘.
    private bool can_export_item_cache (ItemData item) {
        if (item == null || item.item_type != "file" || item.file_path == null || work_dir == null) {
            return false;
        }
        var cache = new PreprocessCache (work_dir.get_path ());
        string hash = PreprocessCache.compute_file_hash (item.file_path);
        return hash.length > 0 && cache.has_cache (hash);
    }

    // 把某文件对应的完整独立缓存子文件夹 ({hash}/, 内含 md/content.md 与 imgs/) 导出为
    // 扁平结构到用户用 Gtk.FileDialog 选定的目标父目录: report_md/content.md + report_md/imgs/.
    // 目标文件夹默认命名为原文件名去扩展名 + "_md" 后缀 (例: report.pdf -> report_md),
    // 与磁盘缓存的 {hash} 命名解耦. 若用户选定父目录下已存在同名文件夹, 自动追加 _1/_2 ... 避免覆盖.
    private void export_item_cache (ItemData item) {
        if (item == null || item.item_type != "file" || item.file_path == null || work_dir == null) {
            show_toast (_("Cannot export cache: no source file or workspace."));
            return;
        }
        var cache = new PreprocessCache (work_dir.get_path ());
        string hash = PreprocessCache.compute_file_hash (item.file_path);
        if (hash.length == 0 || !cache.has_cache (hash)) {
            show_toast (_("No cache folder found for this item."));
            return;
        }
        string? folder_name = item.export_folder_name ();
        if (folder_name == null || folder_name.length == 0) {
            folder_name = hash;
        }

        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Export Cache Folder");
        dialog.initial_folder = work_dir;
        dialog.select_folder.begin (this, null, (obj, res) => {
            try {
                File dest_parent = dialog.select_folder.end (res);
                if (dest_parent == null) return;
                string dest_path = cache.export_cache_folder (hash, dest_parent, folder_name);
                show_toast (_("Cache folder exported to %s").printf (dest_path));
            } catch (GLib.Error err) {
                if (!(err is Gtk.DialogError.DISMISSED)) {
                    GLib.warning ("Export cache folder failed: %s", err.message);
                    show_toast (_("Export failed: %s").printf (err.message));
                }
            }
        });
    }

    // show_queue_context_menu 已移至 setup_queue_list 附近, 集成右键 selection
    // 同步逻辑 (原来 selection 同步在 QueueListFactory 内部完成, 抽离后由
    // Window 集中处理).

    // ─── 目录树右键菜单 ─────────────────────────────────────────────────────

    // 与编排列表右键菜单相同的修复: 避免把捕获 item 的 lambda 传给 ContextMenus,
    // 否则 target 是临时闭包数据, popover 触发时已成为野指针.
    private DirectoryItem? ctx_tree_item = null;

    private void on_ctx_tree_copy_path () {
        if (ctx_tree_item == null) return;
        string path_to_copy = ctx_tree_item.path;
        if (work_dir != null) {
            string wd = work_dir.get_path () + "/";
            if (path_to_copy.has_prefix (wd)) {
                path_to_copy = path_to_copy.substring (wd.length);
            }
        }
        get_clipboard ().set_text (path_to_copy);
    }

    private void on_ctx_tree_show_folder () {
        if (ctx_tree_item == null) return;
        string target_path = ctx_tree_item.is_dir ? ctx_tree_item.path : GLib.Path.get_dirname (ctx_tree_item.path);
        show_file_in_folder (target_path);
    }

    private void on_ctx_tree_copy_content () {
        if (ctx_tree_item == null) return;
        try {
            uint8[] data;
            FileUtils.get_data (ctx_tree_item.path, out data);
            if (data.length > 1048576) {
                show_toast (_("File too large to copy content"));
                return;
            }
            string content = EncodingHelper.decode_to_utf8 (data);
            get_clipboard ().set_text (content);
            show_toast (_("File content copied"));
        } catch (Error e) {
            show_toast (_("Failed to read file"));
        }
    }

    private void on_ctx_tree_select_lines () {
        if (ctx_tree_item == null) return;

        var dialog = new Adw.Dialog ();
        dialog.set_title (_("Select Lines"));
        dialog.set_content_width (400);

        var toolbar_view = new Adw.ToolbarView ();
        var header = new Adw.HeaderBar ();
        header.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header);

        var cancel_btn = new Gtk.Button.with_label (_("Cancel"));
        header.pack_start (cancel_btn);
        cancel_btn.clicked.connect (() => dialog.close ());

        var add_btn = new Gtk.Button.with_label (_("Add"));
        add_btn.add_css_class ("suggested-action");
        header.pack_end (add_btn);

        var group = new Adw.PreferencesGroup ();
        group.set_description (
            _("Enter line ranges, comma-separated, hyphen for intervals.\nExample: 1-10,15,20-25")
        );

        var entry = new Adw.EntryRow ();
        entry.set_title (_("Line Range"));
        group.add (entry);

        var prefs_page = new Adw.PreferencesPage ();
        prefs_page.add (group);

        toolbar_view.set_content (prefs_page);
        dialog.set_child (toolbar_view);

        add_btn.clicked.connect (() => {
            string text = entry.get_text ().strip ();
            if (text.length > 0) {
                add_line_ranges_to_queue (ctx_tree_item, text);
                dialog.close ();
            }
        });

        entry.activate.connect (() => {
            string text = entry.get_text ().strip ();
            if (text.length > 0) {
                add_line_ranges_to_queue (ctx_tree_item, text);
                dialog.close ();
            }
        });

        dialog.present (this);
    }

    private void add_line_ranges_to_queue (DirectoryItem item, string input) {
        // 解析行范围: 1-10,15,20-25
        string[] parts = input.split (",");
        var starts = new Gee.ArrayList<int> ();
        var ends = new Gee.ArrayList<int> ();
        foreach (string part in parts) {
            string trimmed = part.strip ();
            if (trimmed.length == 0) continue;
            if (trimmed.contains ("-")) {
                string[] bounds = trimmed.split ("-", 2);
                int start = int.parse (bounds[0].strip ());
                int end = int.parse (bounds[1].strip ());
                if (start > 0 && end > 0) {
                    // 起始/结束填反时自动纠正顺序并提示，避免直接拒绝导致内容丢失。
                    if (start > end) {
                        int t = start; start = end; end = t;
                        show_toast (_("Line range %s: start line > end line, auto-swapped").printf (trimmed));
                    }
                    starts.add (start);
                    ends.add (end);
                } else {
                    show_toast (_("Invalid line range: %s").printf (trimmed));
                    return;
                }
            } else {
                int line = int.parse (trimmed);
                if (line > 0) {
                    starts.add (line);
                    ends.add (line);
                } else {
                    show_toast (_("Invalid line number: %s").printf (trimmed));
                    return;
                }
            }
        }

        if (starts.size == 0) {
            show_toast (_("No valid line range entered"));
            return;
        }

        push_undo_state ();
        for (int i = 0; i < starts.size; i++) {
            var new_item = new ItemData ("file", item.path, null, false);
            new_item.start_line = starts.get (i);
            new_item.end_line = ends.get (i);
            items.add (new_item);
        }
        refresh_list ();
        update_token_display ();
    }

    private void show_tree_context_menu (Gtk.Widget parent, DirectoryItem item, int gx, int gy) {
        ctx_tree_item = item;
        // 目录树右键导出: 用 item.path 构造一个临时 ItemData 以复用导出逻辑与判定.
        var tmp = new ItemData ("file", item.path, null, false);
        bool can_export = !item.is_dir && can_export_item_cache (tmp);
        ContextMenus.show_tree_menu (
            parent, item, gx, gy, work_dir,
            on_ctx_tree_copy_path,
            on_ctx_tree_show_folder,
            on_ctx_tree_copy_content,
            on_ctx_tree_select_lines,
            () => export_item_cache (tmp),
            can_export
        );
    }

    // ─── 系统级辅助方法 ─────────────────────────────────────────────────────

    private void show_file_in_folder (string path) {
        UIHelpers.show_file_in_folder (this, path);
    }

    // ─── Options ─────────────────────────────────────────────────────────

    private void on_path_mode_changed () {
        bool old_abs = use_absolute;
        bool old_hdr = show_header;
        use_absolute = radio_absolute_path.active;
        push_undo_delta (new UndoDelta.for_absolute (old_abs, use_absolute, old_hdr, show_header));
        refresh_list ();
        update_token_display ();
    }

    private void on_header_check_changed () {
        bool old_val = show_header;
        show_header = check_write_header.active;
        push_undo_delta (new UndoDelta.for_header (old_val, show_header));
        update_token_display ();
    }

    // ─── Generate ────────────────────────────────────────────────────────

    private void on_generate_clicked () {
        if (items.size == 0) {
            show_toast (_("The queue is empty. Please check some files or add text content first"));
            return;
        }

        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Export Merged Text");

        var filter_txt = new Gtk.FileFilter ();
        filter_txt.name = _("Text File (*.txt)");
        filter_txt.add_pattern ("*.txt");

        var filter_md = new Gtk.FileFilter ();
        filter_md.name = _("Markdown (*.md)");
        filter_md.add_pattern ("*.md");

        var filter_json = new Gtk.FileFilter ();
        filter_json.name = _("JSON (*.json)");
        filter_json.add_pattern ("*.json");

        var filter_jsonl = new Gtk.FileFilter ();
        filter_jsonl.name = _("JSONL (*.jsonl)");
        filter_jsonl.add_pattern ("*.jsonl");

        var filter_ipynb = new Gtk.FileFilter ();
        filter_ipynb.name = _("Jupyter Notebook (*.ipynb)");
        filter_ipynb.add_pattern ("*.ipynb");

        var filter_all = new Gtk.FileFilter ();
        filter_all.name = _("All Files (*)");
        filter_all.add_pattern ("*");

        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter_txt);
        filters_list.append (filter_md);
        filters_list.append (filter_json);
        filters_list.append (filter_jsonl);
        filters_list.append (filter_ipynb);
        filters_list.append (filter_all);
        dialog.set_filters (filters_list);
        dialog.set_default_filter (filter_txt);
        if (work_dir != null) dialog.initial_folder = work_dir;

        var now = new DateTime.now_local ();
        dialog.set_initial_name (
            "filecollector-export-%s".printf (now.format ("%Y%m%d-%H%M%S"))
        );

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                string lower = path.down ();
                string fmt_name;
                if (lower.has_suffix (".md")) {
                    MultiFormatExporter.export_markdown (path, items, use_absolute, show_header, work_dir);
                    fmt_name = _("Markdown");
                } else if (lower.has_suffix (".jsonl")) {
                    MultiFormatExporter.export_jsonl (path, items, use_absolute, show_header, work_dir);
                    fmt_name = _("JSONL");
                } else if (lower.has_suffix (".json")) {
                    MultiFormatExporter.export_json (path, items, use_absolute, show_header, work_dir);
                    fmt_name = _("JSON");
                } else if (lower.has_suffix (".ipynb")) {
                    MultiFormatExporter.export_ipynb (path, items, use_absolute, show_header, work_dir);
                    fmt_name = _("Jupyter Notebook");
                } else {
                    if (!lower.has_suffix (".txt")) {
                        path += ".txt";
                    }
                    FileGenerator.generate_file (path, items, use_absolute, show_header, work_dir);
                    fmt_name = _("Merged Text");
                }
                show_toast (_("%s saved").printf (fmt_name));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || e is Gtk.DialogError.DISMISSED) {
                    return;
                }
                show_error (_("Save Failed"), e.message);
            }
        });
    }

    private void on_generate_to_clipboard_clicked () {
        if (items.size == 0) {
            show_toast (_("The queue is empty. Please check some files or add text content first"));
            return;
        }

        try {
            FileGenerator.generate_to_clipboard (items, use_absolute, show_header, work_dir, this.get_display ());
            show_toast (_("Merged Text Copied to Clipboard"));
        } catch (Error e) {
            show_error (_("Copy Failed"), e.message);
        }
    }

    // ─── ZIP 导出 ────────────────────────────────────────────────────────

    private void on_export_zip_clicked () {
        if (items.size == 0) {
            show_toast (_("The queue is empty. Please check some files or add text content first"));
            return;
        }

        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Export as ZIP");
        var filter_zip = new Gtk.FileFilter ();
        filter_zip.name = _("ZIP Archive (*.zip)");
        filter_zip.add_pattern ("*.zip");
        var filter_all = new Gtk.FileFilter ();
        filter_all.name = _("All Files (*)");
        filter_all.add_pattern ("*");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter_zip);
        filters_list.append (filter_all);
        dialog.set_filters (filters_list);
        dialog.set_default_filter (filter_zip);
        if (work_dir != null) dialog.initial_folder = work_dir;

        // 默认文件名: filecollector-export-2026-06-28-143012.zip
        var now = new DateTime.now_local ();
        dialog.set_initial_name (
            "filecollector-export-%s.zip".printf (now.format ("%Y%m%d-%H%M%S"))
        );

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".zip")) {
                    path += ".zip";
                }
                // ZIP 导出: 文件是真实文件 (不是 VLM 转写后的 markdown),
                // 所以 use_absolute 只影响 README 中路径显示, 这里传 false 即可
                ZipExporter.export_to_zip (path, items, show_header, work_dir);
                show_toast (_("ZIP exported: %s").printf (GLib.Path.get_basename (path)));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED || e is Gtk.DialogError.DISMISSED) {
                    show_toast (_("Export Cancelled"));
                    return;
                }
                show_error (_("ZIP Export Failed"), e.message);
            }
        });
    }

    // ─── AI 阅读指南生成 ─────────────────────────────────────────────────

    private void on_ai_toc_clicked () {
        if (items.size == 0) {
            show_toast (_("The queue is empty. Please check some files or add text content first"));
            return;
        }

        var s = ConfigManager.load_ai_settings ();
        if (!s.enabled || s.base_url == "" || s.api_key == "" || s.model == "") {
            show_toast (_("Please configure the API in Settings → AI Settings first."));
            return;
        }

        btn_ai_toc.sensitive = false;
        btn_generate.sensitive = false;
        set_win_action_enabled ("generate", false);
        set_win_action_enabled ("generate_to_clipboard", false);
        set_win_action_enabled ("export_zip", false);
        show_toast (_("Generating reading guide with AI..."));

        var client = new AIClient (s.base_url, s.api_key, s.model, s.timeout);
        string context = build_toc_prompt_context ();
        string prompt = build_toc_prompt (context);

        var msgs = new Gee.ArrayList<Json.Node> ();
        var o = new Json.Object ();
        o.set_string_member ("role", "user");
        o.set_string_member ("content", prompt);
        var node = new Json.Node (Json.NodeType.OBJECT);
        node.set_object (o);
        msgs.add (node);

        try {
            new GLib.Thread<void*> ("toc-gen", () => {
                string toc_result = "";
                try {
                    var result = client.chat (msgs, null, null);
                    toc_result = clean_ai_markdown (result.content);
                } catch (Error e) {
                    warning ("TOC Gen failed: %s", e.message);
                }

                Idle.add (() => {
                    if (toc_result.length == 0) {
                        show_toast (_("AI reading guide generation failed"));
                    } else {
                        push_undo_state ();
                        items.insert (0, new ItemData ("text", null, toc_result, false));
                        refresh_list ();
                        show_toast (_("AI reading guide inserted at top of list"));
                    }
                    update_queue_buttons ();
                    return Source.REMOVE;
                });
                return null;
            });
        } catch (ThreadError e) {
            show_toast (_("Failed to start AI generation thread"));
            update_queue_buttons ();
        }
    }

    private string build_toc_prompt_context () {
        return UIHelpers.build_toc_prompt_context (items, work_dir);
    }

    private string build_toc_prompt (string context) {
        return UIHelpers.build_toc_prompt (context);
    }

    private string clean_ai_markdown (string raw) {
        return UIHelpers.clean_ai_markdown (raw);
    }

    // ─── Project ─────────────────────────────────────────────────────────

    public void on_open_project () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Open Project");
        var filter = new Gtk.FileFilter ();
        filter.name = _("Project File (*.fcol, *.fcol.json, *.project.json)");
        filter.add_pattern ("*.fcol");
        filter.add_pattern ("*.fcol.json");
        filter.add_pattern ("*.project.json");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);
        if (work_dir != null) dialog.initial_folder = work_dir;

        dialog.open.begin (this, null, (obj, res) => {
            try {
                var file = dialog.open.end (res);
                project_controller.load (file.get_path ());
                undo_manager.clear ();
                update_ui_after_project_load ();
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                show_error (_("Open Failed"), e.message);
            }
        });
    }

    private void update_ui_after_project_load () {
        // 加载新项目后, 当前编辑内容归属于第一个工作区; 先复位激活索引,
        // 避免 work_dir setter 的 sync_active_snapshot 写入旧的/越界的索引.
        active_workspace_index = 0;
        if (work_dir != null) {
            update_subtitle (work_dir.get_path ());
            root_store.remove_all ();
            var root_item = new DirectoryItem (work_dir.get_basename (), work_dir.get_path (), true);
            root_store.append (root_item);

            // 【核心修复】清理 checked_dirs 中的过时条目
            // checked_paths 在加载时按文件系统存在性过滤, 但 checked_dirs 未过滤
            // 若文件在保存后被删除, 其所在目录仍留在 checked_dirs 中, 但实际已非全选
            // 遍历 items, 找出不在 checked_files 中的文件 (缺失文件), 移除其祖先目录的 checked_dirs 标记
            foreach (var item in items) {
                if (item.item_type == "file" && !(item.file_path in check_model.checked_files)) {
                    check_model.remove_ancestors_from_checked_dirs (item.file_path);
                }
            }

            // 确保所有已勾选文件的祖先目录被标记或预加载
            // 防止深层目录因未展开导致 implicit_checked_dirs 断层或统计遗漏
            foreach (var path in check_model.checked_files) {
                ensure_path_loaded (path);
            }

            load_directory_children_lazy (root_item);
            search_entry.visible = true;
            var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
            if (root_row != null) root_row.set_expanded (true);
        } else {
            update_subtitle (null);
        }
        update_action_sensitivity ();
        update_workdir_dependent_buttons ();
        refresh_list ();
        update_empty_state ();
        foreach (var it in items) {
            if (it.item_type == "text") it.update_token_stats ();
        }
        update_token_display ();
        // 加载的项目不含任何快照时, 补一个默认工作区, 保持侧栏非空
        app_state.ensure_default_snapshot ();
        // 激活第一个工作区 (加载后当前编辑内容归属于它)
        active_workspace_index = 0;
        snapshot_sidebar.set_selected (0);
    }

    public void on_save_project () {
        try {
            if (project_controller.save_current ()) {
                show_toast (_("Project file updated"));
            } else {
                on_save_project_as ();
            }
        } catch (Error e) {
            show_error (_("Save Failed"), e.message);
        }
    }

    public void on_save_project_as () {
        var dialog = new Gtk.FileDialog ();
        dialog.title = _("Save Project");
        var filter = new Gtk.FileFilter ();
        filter.name = _("Project File (*.fcol)");
        filter.add_pattern ("*.fcol");
        var filters_list = new GLib.ListStore (typeof (Gtk.FileFilter));
        filters_list.append (filter);
        dialog.set_filters (filters_list);
        if (work_dir != null) dialog.initial_folder = work_dir;

        dialog.save.begin (this, null, (obj, res) => {
            try {
                var file = dialog.save.end (res);
                var path = file.get_path ();
                if (!path.has_suffix (".fcol")) {
                    path += ".fcol";
                }
                project_controller.save (path);
                show_toast (_("Project file saved"));
            } catch (Error e) {
                if (e is GLib.IOError.CANCELLED) return;
                show_error (_("Save Failed"), e.message);
            }
        });
    }

    // ─── Subtitle ────────────────────────────────────────────────────────

    private void cache_title_widget () {
        if (_title_widget == null) {
            var header = get_titlebar () as Adw.HeaderBar;
            if (header != null && header.title_widget is Adw.WindowTitle) {
                _title_widget = (Adw.WindowTitle) header.title_widget;
            } else {
                _title_widget = find_window_title (this);
            }
        }
    }

    private void update_subtitle (string? text) {
        string subtitle = text ?? _("No Working Directory Set");

        if (_title_widget == null) {
            cache_title_widget ();
        }
        if (_title_widget != null) {
            _title_widget.set_subtitle (subtitle);
        }
    }

    private Adw.WindowTitle? find_window_title (Gtk.Widget root) {
        if (root is Adw.WindowTitle) {
            return (Adw.WindowTitle) root;
        }

        var child = root.get_first_child ();
        while (child != null) {
            var found = find_window_title (child);
            if (found != null) {
                return found;
            }
            child = child.get_next_sibling ();
        }
        return null;
    }

    // ─── Dialogs ─────────────────────────────────────────────────────────

    public void on_about () {
        var about = new Adw.AboutDialog ();
        about.application_name = _("FileCollector");
        about.version = Config.VERSION;
        about.application_icon = "io.github.sam_fic.filecollector";
        about.comments = _("File Collection & Organization Tool");
        about.developers = { "Sam-Fic" };
        about.website = "https://github.com/Sam-Fic/filecollector";
        about.license_type = Gtk.License.MIT_X11;

        about.present (this);
    }

    public void on_show_shortcuts () {
        try {
            var builder = new Gtk.Builder ();
            builder.set_translation_domain (Config.GETTEXT_PACKAGE);
            builder.add_from_string (ShortcutsHelper.build_ui (), -1);
            var win = builder.get_object ("sw") as Adw.ShortcutsDialog;
            if (win == null) return;
            win.present (this);
        } catch (Error e) {
            warning ("Failed to show shortcuts: %s", e.message);
        }
    }

    public void on_preferences () {
        if (preferences_dialog_instance == null) {
            preferences_dialog_instance = new PreferencesDialog (this);
            preferences_dialog_instance.ai_settings_changed.connect (() => {
                apply_ai_settings_to_panel ();
                reevaluate_queue_against_allowed_exts ();
            });
            preferences_dialog_instance.context_settings_changed.connect (() => {
                current_context_limit = ConfigManager.get_context_window_size ();
                update_token_display ();
            });
            preferences_dialog_instance.restart_requested.connect (() => {
                var app = (FileCollectorApp) this.application;
                app.quit ();
                Platform.restart_app ();
            });
        }
        preferences_dialog_instance.present ();
    }

    public void on_manage_phrases () {
        get_phrases_picker ().show_manage_window ();
    }

    private TemplatesManager? templates_manager_instance = null;

    public void on_manage_templates () {
        if (templates_manager_instance == null) {
            templates_manager_instance = new TemplatesManager (this);
        }
        templates_manager_instance.present ();
    }

    private void show_error (string title, string msg) {
        var d = new Adw.AlertDialog (title, msg);
        d.add_response ("ok", _("OK"));
        d.present (this);
    }

    private void show_toast (string title) {
        var toast = new Adw.Toast (title);
        toast.timeout = 2;
        toast_overlay.add_toast (toast);
    }

    private void show_edit_phrase_dialog (string old_text, int index) {
        var picker = get_phrases_picker ();
        var dialog = new Adw.Dialog ();
        dialog.set_title (_("Edit Common Phrase"));
        dialog.set_content_width (450);
        dialog.set_content_height (350);

        var toolbar_view = new Adw.ToolbarView ();
        dialog.set_child (toolbar_view);

        var header_bar = new Adw.HeaderBar ();
        header_bar.set_title_widget (new Adw.WindowTitle (_("Edit Common Phrase"), ""));
        header_bar.set_show_end_title_buttons (false);
        toolbar_view.add_top_bar (header_bar);

        var cancel_btn = new Gtk.Button ();
        cancel_btn.set_label (_("Cancel"));
        header_bar.pack_start (cancel_btn);

        var ok_btn = new Gtk.Button ();
        ok_btn.set_label (_("OK"));
        ok_btn.add_css_class ("suggested-action");
        header_bar.pack_end (ok_btn);

        var btn_size_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
        btn_size_group.add_widget (cancel_btn);
        btn_size_group.add_widget (ok_btn);

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        content.set_margin_top (0);
        content.set_margin_start (12);
        content.set_margin_end (12);
        content.set_margin_bottom (12);

        var frame = new Gtk.Frame (null);
        frame.add_css_class ("card");
        frame.add_css_class ("ai-input-frame");

        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.set_vexpand (true);
        scrolled.set_min_content_height (120);

        var text_view = new Gtk.TextView ();
        text_view.set_wrap_mode (Gtk.WrapMode.WORD_CHAR);
        text_view.set_top_margin (12);
        text_view.set_bottom_margin (12);
        text_view.set_left_margin (12);
        text_view.set_right_margin (12);
        text_view.get_buffer ().set_text (old_text, -1);

        scrolled.set_child (text_view);
        frame.set_child (scrolled);
        content.append (frame);

        toolbar_view.set_content (content);

        cancel_btn.clicked.connect (() => {
            dialog.close ();
        });

        ok_btn.clicked.connect (() => {
            var buffer = text_view.get_buffer ();
            Gtk.TextIter start, end;
            buffer.get_start_iter (out start);
            buffer.get_end_iter (out end);
            var text = buffer.get_text (start, end, false);
            if (text != null && text.strip () != "") {
                picker.update_phrase (index, text);
            }
            dialog.close ();
        });

        dialog.present (this);
    }

    private PhrasesPicker get_phrases_picker () {
        if (phrases_picker_instance == null) {
            phrases_picker_instance = new PhrasesPicker (this, common_phrases);
            phrases_picker_instance.phrase_selected.connect ((phrase, above) => {
                do_insert_text (phrase, above);
            });
            phrases_picker_instance.edit_phrase_requested.connect ((old_text, index) => {
                show_edit_phrase_dialog (old_text, index);
            });
        }
        return phrases_picker_instance;
    }

    // ─── Token 估算 ────────────────────────────────────────────────────

    private void update_token_display () {
        int total_tokens = 0;

        if (show_header && work_dir != null) {
            string header = _("# Working directory absolute path: ") + work_dir.get_path () + "\n\n";
            total_tokens += TokenEstimator.estimate_tokens_fast (header);
        }

        for (int i = 0; i < items.size; i++) {
            if (i > 0) total_tokens += 1;

            var data = items.get (i);
            if (data.item_type == "file" && data.file_path != null) {
                string display = get_display_path (data);
                total_tokens += TokenEstimator.estimate_tokens_fast (display + ":\n");

                if (data.preprocessed_content != null && data.preprocessed_content.length > 0) {
                    total_tokens += data.cached_tokens;
                } else if (data.is_binary_target ()) {
                    // 二进制文件预处理前不估算 token, 只统计转换后的 Markdown
                } else                 if (data.is_snippet ()) {
                    total_tokens += TokenEstimator.estimate_snippet_tokens_fast (data.file_path, data.start_line, data.end_line);
                } else {
                    total_tokens += TokenEstimator.estimate_file_tokens_fast (data.file_path);
                }
            } else if (data.item_type == "text") {
                total_tokens += data.cached_tokens;
            }
        }

        current_token_ratio = current_context_limit > 0 ? (double) total_tokens / current_context_limit : 0.0;

        btn_generate.tooltip_text = _("Estimated context: %d / %d Tokens (%.1f%%)").printf (
            total_tokens, current_context_limit, current_token_ratio * 100
        );

        token_ring.queue_draw ();
    }


    private string get_display_path (ItemData data) {
        if (data.force_absolute || use_absolute || work_dir == null) return data.file_path;
        var wd_path = work_dir.get_path () + "/";
        if (data.file_path.has_prefix (wd_path)) return data.file_path.substring (wd_path.length);
        return data.file_path;
    }

    // ─── AI 助手集成 ───────────────────────────────────────────────────

    // 在 Vala 中构建 AI 右侧栏与 AdwOverlaySplitView。
    // blueprint 0.19 不能为 OverlaySplitView 正确指派 sidebar/content 子控件
    // (与 snapshot_split 同一限制), 故在此显式 set_sidebar()/set_content()。
    // 层级: snapshot_split > ai_split > main_overlay (> main_view),
    // 侧栏全高、覆盖标题栏所在区域, 与左侧快照栏对称.
    // 响应式: 侧栏 并排/覆盖 切换与窗口最小宽由 update_sidebars_layout
    // (size_allocate 内) 按当前宽度动态判定, 不用静态断点.
    private void build_ai_split_view () {
        ai_sidebar = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        ai_sidebar.vexpand = true;

        // 标题栏: 标准 Adw.HeaderBar + WindowTitle, 与左侧 Workspaces 侧栏同构
        // (见 build_snapshot_split_view). 标准 headerbar 高度与主窗口标题栏一致,
        // 侧栏内容区顶边因此与三卡片的顶线天然对齐.
        var ai_header = new Adw.HeaderBar ();
        ai_header.title_widget = new Adw.WindowTitle (_("AI Assistant"), "");

        var ai_toolbar = new Adw.ToolbarView ();
        ai_toolbar.add_top_bar (ai_header);
        ai_toolbar.content = ai_sidebar;
        ai_toolbar.add_css_class ("ai-panel");

        ai_split = new Adw.OverlaySplitView ();
        ai_split.collapsed = false;
        ai_split.pin_sidebar = true;
        ai_split.show_sidebar = false;
        ai_split.sidebar_position = Gtk.PackType.END;
        ai_split.min_sidebar_width = 360;
        ai_split.max_sidebar_width = 360;
        ai_split.sidebar = ai_toolbar;

        // 占位断点 (条件永不成立, 无任何 setter): 作用是让窗口保持 "可窄".
        // Adw.ApplicationWindow 兼作断点容器, 一旦注册了断点, 其测量申报的最小宽
        // 恒为 0 —— 这正好是我们需要的: 若一个断点都不注册, 测量链会把 "并排侧栏
        // 宽度" 计入窗口最小宽 (三卡片最小宽 ~860 + 280 + 360 ≈ 1500), 窗口缩小到
        // 该值就被卡死, 永远无法过渡到覆盖模式. 占位断点解除该硬下限后, 真正的
        // 窗口最小宽 (三卡片最小宽) 与侧栏 并排/覆盖 判定, 统一由 size_allocate
        // 中的 update_sidebars_layout 动态维护. 不要删除此断点, 也不要给它加条件
        // 以外的东西.
        var placeholder_bp = new Adw.Breakpoint (Adw.BreakpointCondition.parse ("max-width: 1px"));
        this.add_breakpoint (placeholder_bp);

        // 挂接: 先把 main_overlay 从 snapshot_split 摘除 (置空 content, 让 GTK
        // 正确解除父子关系), 再包入 ai_split —— 与 build_snapshot_split_view /
        // setup_vlm_queue 同理: set_content 要求子控件无父级, 否则断言失败.
        snapshot_split.content = null;
        ai_split.content = main_overlay;
        snapshot_split.content = ai_split;
    }

    // 三卡片实测最小宽. 这是窗口硬下限与侧栏 并排/覆盖 阈值共用的唯一数值 ——
    // 两者必须同源, 否则会出现 "阈值说够宽、卡片仍被裁切".
    // 直接取 measure(): gtk_widget_measure 已把 Paned 自身左右边距 (18+18) 与
    // 两个把手宽计入, 再手动加一次边距会把兜底值虚高 36px.
    private int cards_min_width () {
        int cards_min, cards_nat;
        outer_paned.measure (Gtk.Orientation.HORIZONTAL, -1, out cards_min, out cards_nat, null, null);
        return cards_min;
    }

    // 三卡片 + 侧栏的宽度仲裁 (窗口尺寸变化 / 侧栏开关时触发 update_sidebars_layout):
    //
    // 设计约束: 只要窗口上注册过断点 (含下方占位断点), Adw 断点容器就把内容测量
    // 申报的最小宽强制归零 (让窗口窄到能触发断点). 这带来两个后果:
    //   (a) 并排侧栏不再挤占窗口最小宽 —— 这正是我们需要的, 否则双栏并排会把窗口
    //       硬下限抬到 ~1488px, 窗口永远缩不进去、也就无法过渡到覆盖模式;
    //   (b) 三卡片最小宽不再被自动申报 —— 必须用窗口级 width-request 手动兜底,
    //       否则拖窗口边缘可缩到三卡片最小宽以下 → 卡片被裁切.
    //
    // 兜底值必须在 realize 之后测: construct 阶段 CSS/字体上下文尚未就绪, 含文本
    // 子控件的 measure() 会申报出偏小的最小宽, 兜底值随之偏小 → 仍可拖到裁切.
    // 首次呈现前也先同步设一版 (宁小勿无), 随后 Idle 里用真实测量值覆盖.
    private void establish_width_floor () {
        update_width_floor ();
        GLib.Idle.add (() => {
            if (app_state.window_closing) return Source.REMOVE;
            update_width_floor ();
            return Source.REMOVE;
        });
    }

    private bool floor_refresh_scheduled = false;

    // 侧栏并排/覆盖态变化会影响窗口硬下限之外的预算, 但兜底值本身只含三卡片;
    // 卡片内可能因内容加载 (长文件名 / 队列行) 改变真实最小宽, 故统一走 Idle 重测.
    private void schedule_width_floor_refresh () {
        if (floor_refresh_scheduled) return;
        floor_refresh_scheduled = true;
        GLib.Idle.add (() => {
            floor_refresh_scheduled = false;
            if (!app_state.window_closing) {
                update_width_floor ();
            }
            return Source.REMOVE;
        });
    }

    private int width_floor = 0;

    private void update_width_floor () {
        int floor = cards_min_width ();
        width_floor = floor;
        if (floor > 0 && this.width_request != floor) {
            this.width_request = floor;
        }
        dump_layout ("floor");
    }

    // 数值化自检: 出问题时用数字定位, 而不是猜.
    // 用法: FILECOLLECTOR_LAYOUT_DEBUG=1 ./build/filecollector
    //
    // 关注两组数的对比:
    //   outer_alloc / inner_alloc  = 两个 Paned 实际拿到的宽度
    //   cards_min (及各卡片 min)    = 它们需要的宽度
    // 若 outer_alloc < cards_min, 即外层容器欠分配 —— 此时 shrink=false 的钳位区间
    // 上下界互相穿越, 分隔条会跟着鼠标随便走且卡片被裁切; 问题在窗口硬下限, 不在 Paned.
    private bool layout_debug_enabled = false;
    private int last_dumped_width = -1;

    private void dump_layout (string why) {
        if (!layout_debug_enabled) {
            layout_debug_enabled =
                GLib.Environment.get_variable ("FILECOLLECTOR_LAYOUT_DEBUG") != null;
            if (!layout_debug_enabled) return;
        }

        int win_w = this.get_width ();
        if (why == "alloc" && win_w == last_dumped_width) return;
        last_dumped_width = win_w;

        int self_min, self_nat;
        this.measure (Gtk.Orientation.HORIZONTAL, -1, out self_min, out self_nat, null, null);

        int outer_min, outer_nat;
        outer_paned.measure (Gtk.Orientation.HORIZONTAL, -1, out outer_min, out outer_nat, null, null);

        int l_min, l_nat, m_min, m_nat, r_min, r_nat;
        var left = outer_paned.get_start_child ();
        var inner_start = inner_paned.get_start_child ();
        var inner_end = inner_paned.get_end_child ();
        left.measure (Gtk.Orientation.HORIZONTAL, -1, out l_min, out l_nat, null, null);
        inner_start.measure (Gtk.Orientation.HORIZONTAL, -1, out m_min, out m_nat, null, null);
        inner_end.measure (Gtk.Orientation.HORIZONTAL, -1, out r_min, out r_nat, null, null);

        stdout.printf (
            "[layout/%s] win=%dx%d win_measure_min=%d floor=%d | need: outer=%d (L=%d M=%d R=%d) | got: outer=%d inner=%d pos=%d/%d shrink=%d%d/%d%d | snap(show=%s dock=%s) ai(show=%s dock=%s)\n",
            why, win_w, this.get_height (), self_min, width_floor,
            outer_min, l_min, m_min, r_min,
            outer_paned.get_width (), inner_paned.get_width (),
            outer_paned.position, inner_paned.position,
            outer_paned.shrink_start_child ? 1 : 0, outer_paned.shrink_end_child ? 1 : 0,
            inner_paned.shrink_start_child ? 1 : 0, inner_paned.shrink_end_child ? 1 : 0,
            snapshot_split.show_sidebar ? "y" : "n",
            snapshot_split.collapsed ? "n" : "y",
            ai_split.show_sidebar ? "y" : "n",
            ai_split.collapsed ? "n" : "y");
    }

    // 侧栏 并排/覆盖 逐个判定 (可在任意时刻安全调用, 只改 collapsed 不改窗口尺寸):
    // 某侧栏仅当 "窗口宽度 >= 三卡片最小宽 + 所有并排侧栏宽(含自身)" 时才并排, 否则覆盖.
    // 左侧优先占用宽度预算, 剩余预算够才并排右侧 —— 双开侧栏时共享预算, 修复旧静态断点
    // 只看窗口总宽、双开时宽度不够导致三卡片被挤到最小宽以下的问题; 单开一侧预算独享,
    // 不误切覆盖. 阈值以当前实际窗口宽度为准 (宽度参数由调用方传入).
    private void update_sidebars_layout (int width) {
        int cards_min = cards_min_width ();

        int left_w = (int) snapshot_split.min_sidebar_width;
        int right_w = (int) ai_split.min_sidebar_width;
        bool dock_left = snapshot_split.show_sidebar && width >= cards_min + left_w;
        bool dock_right = ai_split.show_sidebar
            && width >= cards_min + (dock_left ? left_w : 0) + right_w;
        bool left_collapsed = snapshot_split.show_sidebar && !dock_left;
        bool right_collapsed = ai_split.show_sidebar && !dock_right;

        bool changed = false;
        // 只在该侧栏 *当前可见* 时才动 collapsed: 收回侧栏时 OverlaySplitView 正在播
        // 滑出动画, 此刻把 collapsed 从 true 翻回 false 会让它瞬时切到 "并排" 布局 ——
        // 内容区先被挤窄一个侧栏宽再弹回, 表现为下层界面闪一下. 隐藏态下 collapsed
        // 无视觉作用, 保持原值即可; 下次显示时 notify::show-sidebar 会重新判定.
        if (snapshot_split.show_sidebar && snapshot_split.collapsed != left_collapsed) {
            snapshot_split.collapsed = left_collapsed;
            changed = true;
        }
        if (ai_split.show_sidebar && ai_split.collapsed != right_collapsed) {
            ai_split.collapsed = right_collapsed;
            changed = true;
        }
        if (changed) {
            dump_layout ("collapse");
        }
    }

    // 侧栏开关时可能不改变窗口宽度 (并排抢内容宽 / 覆盖不占宽), 此时 size_allocate
    // 不一定触发, 故显式按当前窗口宽重算一次折叠态.
    private void reevaluate_sidebars () {
        int w = this.get_width ();
        if (w > 0) {
            update_sidebars_layout (w);
        }
        schedule_width_floor_refresh ();
    }

    public override void size_allocate (int width, int height, int baseline) {
        update_sidebars_layout (width);
        base.size_allocate (width, height, baseline);
        dump_layout ("alloc");
    }

    private void setup_ai_panel () {
        ai_panel_visible = false;
        ai_split.show_sidebar = false;

        // 按钮 active 与侧栏可见性双向绑定 (同 btn_toggle_snapshot 模式):
        // 不再连 clicked —— 点击经 binding 自动翻转 show-sidebar,
        // Ctrl+J 编程式翻转时按钮按下态也自动同步.
        btn_ai_toggle.bind_property (
            "active", ai_split, "show-sidebar",
            GLib.BindingFlags.BIDIRECTIONAL | GLib.BindingFlags.SYNC_CREATE
        );

        // 可见性变化时处理懒创建 / 窗口加宽恢复
        ai_split.notify["show-sidebar"].connect (on_ai_sidebar_toggled);
        ai_split.notify["show-sidebar"].connect (reevaluate_sidebars);
    }

    private void on_ai_sidebar_toggled () {
        bool show = ai_split.show_sidebar;
        if (show == ai_panel_visible) return;
        ai_panel_visible = show;
        // 收起时无额外处理: 呈现由 split view 自管理, 窗口宽度不随之变化
        if (show) {
            show_ai_panel ();
        }
    }

    // ─── 全局内容搜索 ────────────────────────────────────────────────────

    private void on_global_search () {
        if (work_dir == null) {
            show_toast (_("Set working directory"));
            return;
        }
        var dialog = new GlobalSearchDialog (this, work_dir.get_path ());
        dialog.add_files_requested.connect ((paths) => {
            push_undo_state ();
            int added = 0;
            foreach (var p in paths) {
                if (!path_in_items (p)) {
                    var new_item = new ItemData ("file", p, null, false);
                    items.add (new_item);
                    if (new_item.is_allowed_binary_target (ConfigManager.get_allowed_binary_extensions ())) {
                        enqueue_item_for_preprocess (new_item);
                    }
                    if (!(p in check_model.checked_files)) {
                        check_model.add_files ({ p });
                    }
                    added++;
                }
            }
            refresh_all_tree_states ();
            refresh_list ();
        });
        dialog.present (this);
    }

    private void toggle_ai_panel () {
        ai_split.show_sidebar = !ai_split.show_sidebar;
    }

    private void show_ai_panel () {
        // 第一次显示时构建 panel
        if (ai_panel_instance == null) {
            ai_panel_instance = new AIPanel (this);
            var content = ai_panel_instance.build_widget ();
            // ai_sidebar 是 OverlaySplitView 的原生侧栏容器, 直接放入内容
            ai_sidebar.append (content);

            ai_panel_instance.get_undo_token.connect (() => {
                return undo_manager.get_stack_size ();
            });
            ai_panel_instance.revert_to_undo_token.connect ((token) => {
                bool needs_refresh = false;
                undo_manager.set_in_progress (true);
                while (undo_manager.can_undo && undo_manager.get_stack_size () > token) {
                    var delta = undo_manager.pop_undo ();
                    if (delta == null) break;
                    var redo_delta = build_redo_delta (delta);
                    apply_undo_delta (delta);
                    undo_manager.push_redo (redo_delta);
                    if (delta.op != UndoOp.SNAPSHOT) {
                        needs_refresh = true;
                    }
                }
                undo_manager.set_in_progress (false);
                if (needs_refresh) {
                    refresh_list ();
                    refresh_all_tree_states ();
                    dir_column_view.queue_draw ();
                }
                update_action_sensitivity ();
            });
            ai_panel_instance.template_triggered.connect ((header, footer) => {
                push_undo_state ();
                if (header != null && header.strip ().length > 0) {
                    app_state.add_item (new ItemData ("text", null, header, false), 0);
                }
                if (footer != null && footer.strip ().length > 0) {
                    app_state.add_item (new ItemData ("text", null, footer, false), -1);
                }
                refresh_list ();
            });
            ai_panel_instance.task_completed.connect (on_ai_task_completed);
        }
        // 重新应用当前设置
        apply_ai_settings_to_panel ();

        // 侧栏显隐完全由 show-sidebar 属性驱动; 并排/覆盖与窗口最小宽由
        // update_sidebars_layout 按当前宽度动态维护, 无需在此处理窗口尺寸.
    }

    // AI 任务完成通知: 仅窗口不在前台时提醒 (HIG: 不打扰正在查看应用的用户),
    // 点击通知经 app.present 动作回到窗口。图标用单色应用符号图标
    // (通知/托盘等单色场景专用), 未安装到系统图标主题的环境回退到全彩应用图标。
    private void on_ai_task_completed (string summary) {
        if (is_active) return;
        var app = get_application ();
        if (app == null) return;

        string body = summary.strip ();
        if (body.length == 0) {
            body = _("Open the AI sidebar to view the full reply.");
        }
        var notification = new GLib.Notification (_("AI task completed"));
        notification.set_body (body);
        notification.set_icon (new GLib.ThemedIcon.from_names ({
            "io.github.sam_fic.filecollector-symbolic",
            "io.github.sam_fic.filecollector"}));
        notification.set_default_action ("app.present");
        app.send_notification ("ai-task-completed", notification);
    }

    private void apply_ai_settings_to_panel () {
        if (ai_panel_instance == null) return;
        var s = ConfigManager.load_ai_settings ();
        if (!s.enabled) {
            ai_panel_instance.configure (s, ai_controller.execute_tool, ai_controller.get_system_snapshot);
            return;
        }
        ai_panel_instance.configure (s, ai_controller.execute_tool, ai_controller.get_system_snapshot);
    }

    // 允许扩展名列表变化后, 重新评估编排列表中各项
    private void reevaluate_queue_against_allowed_exts () {
        string[] allowed = ConfigManager.get_allowed_binary_extensions ();
        foreach (var item in items) {
            if (item.item_type != "file") continue;
            if (item.is_allowed_binary_target (allowed)) {
                // 重新进入允许列表: 此前因为不在列表中而未触发缓存检查, 现在补上
                if (item.preprocess_status == PreprocessStatus.NONE
                    || item.preprocess_status == PreprocessStatus.FAILED) {
                    enqueue_item_for_preprocess (item);
                }
            } else {
                // 移出允许列表: 清空预处理状态, 不再显示 AI 相关 UI
                if (item.preprocess_status != PreprocessStatus.NONE) {
                    item.preprocess_status = PreprocessStatus.NONE;
                    item.preprocessed_content = null;
                    item.from_cache = false;
                }
            }
        }
        refresh_list ();
    }

    // AIController.work_dir_change_requested 信号处理: 切换工作目录并刷新 UI
    private void ai_apply_set_work_dir (string path) {
        push_undo_state ();
        app_state.items.clear ();
        app_state.check_model.clear ();
        var folder = File.new_for_path (path);
        work_dir = folder;
        update_subtitle (path);
        root_store.remove_all ();
        var root_item = new DirectoryItem (folder.get_basename (), path, true);
        root_store.append (root_item);
        load_directory_children_lazy (root_item);
        search_entry.visible = true;
        var root_row = tree_list_model.get_item (0) as Gtk.TreeListRow;
        if (root_row != null) {
            root_row.set_expanded (true);
        }
        refresh_list ();
    }
}
