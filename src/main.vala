using Gee;

public class FileCollectorApp : Adw.Application {
    private FileCollectorWindow? app_window = null;

    public FileCollectorApp () {
        Object (
            application_id: "io.github.sam_fic.filecollector",
            flags: ApplicationFlags.HANDLES_COMMAND_LINE
        );
    }

    protected override void activate () {
        var window = app_window;
        if (window == null) {
            window = new FileCollectorWindow (this);
            app_window = window;

            var open_action = lookup_action ("open_project");
            if (open_action != null) {
                ((GLib.SimpleAction) open_action).activate.connect (() => window.on_open_project ());
            }

            var save_action = lookup_action ("save_project");
            if (save_action != null) {
                ((GLib.SimpleAction) save_action).activate.connect (() => window.on_save_project ());
            }

            var save_as_action = lookup_action ("save_as_project");
            if (save_as_action != null) {
                ((GLib.SimpleAction) save_as_action).activate.connect (() => window.on_save_project_as ());
            }

            var about_action = lookup_action ("about");
            if (about_action != null) {
                ((GLib.SimpleAction) about_action).activate.connect (() => window.on_about ());
            }

            var phrases_action = lookup_action ("manage_phrases");
            if (phrases_action != null) {
                ((GLib.SimpleAction) phrases_action).activate.connect (() => window.on_manage_phrases ());
            }
            var templates_action = lookup_action ("manage_templates");
            if (templates_action != null) {
                ((GLib.SimpleAction) templates_action).activate.connect (() => window.on_manage_templates ());
            }

            var preferences_action = lookup_action ("preferences");
            if (preferences_action != null) {
                ((GLib.SimpleAction) preferences_action).activate.connect (() => window.on_preferences ());
            }

            var clear_cache_action = lookup_action ("clear_cache");
            if (clear_cache_action != null) {
                ((GLib.SimpleAction) clear_cache_action).activate.connect (() => window.on_clear_cache ());
            }

            var shortcuts_action = lookup_action ("shortcuts");
            if (shortcuts_action != null) {
                ((GLib.SimpleAction) shortcuts_action).activate.connect (() => window.on_show_shortcuts ());
            }

            var quit_action = lookup_action ("quit");
            if (quit_action != null) {
                ((GLib.SimpleAction) quit_action).activate.connect (() => window.close ());
            }

            // 通知默认动作: 点击 "AI 任务完成" 通知时把窗口带回前台
            var present_action = lookup_action ("present");
            if (present_action != null) {
                ((GLib.SimpleAction) present_action).activate.connect (() => window.present ());
            }
        }

        window.present ();

        // 确保从 build 目录运行时也能解析应用图标
        setup_app_icon_resource ();
    }

    protected override int command_line (ApplicationCommandLine command_line) {
        var args = command_line.get_arguments ();

        // 防御: get_arguments 理论上至少返回程序名, 但显式校验避免边界情况下越界
        if (args.length == 0) {
            return 0;
        }

        bool force_gui = false;
        var filtered = new Gee.ArrayList<string> ();
        filtered.add (args[0]);
        for (int i = 1; i < args.length; i++) {
            if (args[i] == "--gui") {
                force_gui = true;
            } else {
                filtered.add (args[i]);
            }
        }
        var filtered_args = (string[]) filtered.to_array ();

        bool has_cli_args = CliController.is_cli_mode (filtered_args);

        if (app_window != null) {
            if (has_cli_args) {
                var cli = app_window.create_cli_from_state ();
                if (cli.parse_args (filtered_args)) {
                    if (cli.execute_save_export ()) {
                        app_window.apply_cli_operations (cli);
                        for (int i = 0; i < cli.operation_messages.size; i++) {
                            command_line.print ("✓ %s\n".printf (cli.operation_messages.get (i)));
                        }
                    } else {
                        for (int i = 0; i < cli.operation_messages.size; i++) {
                            command_line.printerr ("✗ %s\n".printf (cli.operation_messages.get (i)));
                        }
                        return 1;
                    }
                } else {
                    return 1;
                }
            } else {
                app_window.present ();
            }
            return 0;
        }

        if (!force_gui && has_cli_args) {
            Intl.setlocale (LocaleCategory.ALL, "");
            setup_i18n_default ();
            var cli = new CliController ();
            return cli.run (filtered_args);
        }

        var lang_setting = FileCollectorWindow.load_settings_language ();
        if (lang_setting == "en") {
            GLib.Environment.set_variable ("LANGUAGE", "en", true);
        } else if (lang_setting == "zh") {
            GLib.Environment.set_variable ("LANGUAGE", "zh_CN", true);
        } else {
            GLib.Environment.unset_variable ("LANGUAGE");
        }

        Intl.setlocale (LocaleCategory.ALL, "");
        setup_i18n_default ();

        activate ();

        if (force_gui && has_cli_args) {
            var cli = new CliController ();
            if (cli.parse_args (filtered_args) || cli.items.size > 0 || cli.work_dir != null) {
                if (cli.execute_save_export ()) {
                    GLib.Idle.add (() => {
                        if (app_window != null) {
                            app_window.apply_cli_operations (cli);
                        }
                        return Source.REMOVE;
                    });
                }
            }
        }

        return 0;
    }

    protected override void startup () {
        base.startup ();

        // 启动时应用已保存的主题偏好，否则重启后会回退到跟随系统
        string scheme = ConfigManager.load_color_scheme ();
        if (scheme == "light") {
            Adw.StyleManager.get_default ().set_color_scheme (Adw.ColorScheme.FORCE_LIGHT);
        } else if (scheme == "dark") {
            Adw.StyleManager.get_default ().set_color_scheme (Adw.ColorScheme.FORCE_DARK);
        } else {
            Adw.StyleManager.get_default ().set_color_scheme (Adw.ColorScheme.DEFAULT);
        }

        // Windows HiDPI：GTK4 的 Win32 后端只做整数缩放（150% DPI 被 floor 成 1×），
        // 且忽略 GDK_SCALE，导致组件布局锁在 1× 而文字按真实 144 DPI 渲染成 1.5×，
        // 出现「组件小、文字大」的错位。这里强制把文字 DPI 设为 96（1×），与组件对齐，
        // 使两者比例正确、清晰（代价：在 150% 屏上整体偏小）。无需 DPI 感知 hack，
        // 与 Setzer 的「真原生 1×」方案一致。仅 Windows 需要。
#if WINDOWS
        var hidpi_settings = Gtk.Settings.get_default ();
        if (hidpi_settings != null) {
            hidpi_settings.gtk_xft_dpi = 96 * 1024;
        }
#endif

        add_action (new GLib.SimpleAction ("open_project", null));
        add_action (new GLib.SimpleAction ("save_project", null));
        add_action (new GLib.SimpleAction ("save_as_project", null));
        add_action (new GLib.SimpleAction ("about", null));
        add_action (new GLib.SimpleAction ("manage_phrases", null));
        add_action (new GLib.SimpleAction ("manage_templates", null));
        add_action (new GLib.SimpleAction ("preferences", null));
        add_action (new GLib.SimpleAction ("clear_cache", null));
        add_action (new GLib.SimpleAction ("shortcuts", null));
        add_action (new GLib.SimpleAction ("quit", null));
        add_action (new GLib.SimpleAction ("present", null));

        set_accels_for_action ("app.open_project", {"<Control>o"});
        set_accels_for_action ("app.save_project", {"<Control>s"});
        set_accels_for_action ("app.save_as_project", {"<Control><Shift>s"});
        set_accels_for_action ("app.about", {"F1"});
        set_accels_for_action ("app.shortcuts", {"<Control>slash"});
        set_accels_for_action ("app.preferences", {"<Control>comma"});
        set_accels_for_action ("app.quit", {"<Control>q"});

        setup_app_icon_resource ();
    }

    private void setup_app_icon_resource () {
        var display = Gdk.Display.get_default ();
        if (display == null) return;

        var icon_theme = Gtk.IconTheme.get_for_display (display);

        // Windows/macOS 便携包携带完整的 Adwaita 与 hicolor 主题。显式加入
        // 搜索路径，避免 GTK 在非 GNOME 系统环境中只查宿主系统图标而丢失 symbolic 图标。
        var portable_theme_dir = Platform.get_portable_icon_theme_dir ();
        if (portable_theme_dir != null) {
            icon_theme.add_search_path (portable_theme_dir);
        }

        // xsi-* 图标 (XApp Symbolic Icons, 不在 Adwaita 中):
        // 实测 GTK4 的 IconTheme 不会解析 resource path 中的主题——即使打包了
        // index.theme + 图标 (结构与文件系统完全一致), lookup 仍返回 image-missing;
        // 而相同结构经文件系统 search path 可以正常解析。因此未安装 (deb/flatpak
        // 之外, 如 builddir 直接运行) 时, 把内置图标解包到应用缓存目录再注册,
        // 对 Button / StatusPage 等 IconTheme 消费方统一生效。
        if (!icon_theme.has_icon ("xsi-git-symbolic")) {
            string? local_icons_dir = ensure_local_icons ();
            if (local_icons_dir != null) {
                icon_theme.add_search_path (local_icons_dir);
            }
        }
    }

    // 把 GResource 内置的 hicolor 最小主题解包到 ~/.cache/<app_id>/icons/,
    // 返回该 icons 目录 (作为 IconTheme search path); 失败返回 null。
    private string? ensure_local_icons () {
        string theme_dir = GLib.Path.build_filename (
            GLib.Environment.get_user_cache_dir (), application_id, "icons", "hicolor");
        string actions_dir = GLib.Path.build_filename (theme_dir, "scalable", "actions");
        string index_path = GLib.Path.build_filename (theme_dir, "index.theme");

        try {
            GLib.DirUtils.create_with_parents (actions_dir, 0755);

            if (!GLib.FileUtils.test (index_path, GLib.FileTest.EXISTS)) {
                GLib.FileUtils.set_contents (index_path, MINIMAL_HICOLOR_INDEX);
            }
            copy_resource_to (
                "/io/github/sam_fic/filecollector/icons/hicolor/scalable/actions/xsi-git-symbolic.svg",
                GLib.Path.build_filename (actions_dir, "xsi-git-symbolic.svg"));
            copy_resource_to (
                "/io/github/sam_fic/filecollector/icons/hicolor/scalable/actions/xsi-text-case-symbolic.svg",
                GLib.Path.build_filename (actions_dir, "xsi-text-case-symbolic.svg"));
        } catch (Error e) {
            GLib.warning ("Failed to unpack local icons: %s", e.message);
            return null;
        }

        // .../icons (hicolor 的父目录), 与 IconTheme search path 的主题目录约定一致
        return GLib.Path.get_dirname (theme_dir);
    }

    private void copy_resource_to (string resource_path, string dest_path) throws Error {
        if (GLib.FileUtils.test (dest_path, GLib.FileTest.EXISTS)) return;
        // 图标是 UTF-8 文本 SVG, 直接按字符串解包
        var instr = GLib.resources_open_stream (resource_path, GLib.ResourceLookupFlags.NONE);
        var sb = new StringBuilder ();
        uint8[] tmp = new uint8[4096];
        while (true) {
            ssize_t n = instr.read (tmp);
            if (n <= 0) break;
            sb.append_len ((string) tmp, (ssize_t) n);
        }
        GLib.FileUtils.set_contents (dest_path, sb.str);
    }

    // 最小 hicolor index.theme: GTK 按 index.theme 声明的 Directories 扫描图标,
    // 只列出本应用实际用到的 scalable/actions 子目录即可 (与系统 hicolor 主题合并)
    private const string MINIMAL_HICOLOR_INDEX = """[Icon Theme]
Name=Hicolor
Comment=Fallback icon theme
Directories=scalable/actions

[scalable/actions]
Context=Actions
Type=Scalable
Size=16
MinSize=8
MaxSize=512
""";

    private static void setup_i18n (string locale_dir) {
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, locale_dir);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
        Intl.textdomain (Config.GETTEXT_PACKAGE);
    }

    private static void setup_i18n_default () {
        string locale_dir = Config.LOCALE_DIR;
        bool mo_found = false;

        // 1. 绿色版 / AppImage / 便携包: 相对 exe 或 APPDIR 的 locale 目录
        //    (平台差异由 Platform.get_portable_locale_dir() 内部处理)
        var portable_locale = Platform.get_portable_locale_dir ();
        if (!mo_found && portable_locale != null) {
            locale_dir = portable_locale;
            mo_found = true;
        }

        // 2. AppImage 部署规范: APPDIR 才是程序真正挂载的沙盒内虚拟根路径
        //    (例如 /tmp/.mount_xxxxx/), 多语言文件封包于 $APPDIR/usr/share/locale
        var appdir = GLib.Environment.get_variable ("APPDIR");
        if (!mo_found && appdir != null && appdir.length > 0) {
            var candidate = Path.build_filename (appdir, "usr", "share", "locale");
            if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo"), FileTest.EXISTS)) {
                locale_dir = candidate;
                mo_found = true;
            }
        }

        // 3. XDG 用户数据目录 (如 ~/.local/share), meson install --prefix=~/.local 安装在此
        if (!mo_found) {
            var user_data = GLib.Environment.get_user_data_dir ();
            var candidate = Path.build_filename (user_data, "locale");
            if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo"), FileTest.EXISTS)) {
                locale_dir = candidate;
                mo_found = true;
            }
        }

        // 4. 终极回退: 扫描 XDG 系统层级目录全盘兜底搜索
        if (!mo_found) {
            foreach (unowned string data_dir in GLib.Environment.get_system_data_dirs ()) {
                var candidate = Path.build_filename (data_dir, "locale");
                if (FileUtils.test (Path.build_filename (candidate, "zh_CN", "LC_MESSAGES", Config.GETTEXT_PACKAGE + ".mo"), FileTest.EXISTS)) {
                    locale_dir = candidate;
                    break;
                }
            }
        }

        setup_i18n (locale_dir);
    }

    public static int main (string[] args) {
        var app = new FileCollectorApp ();
        int ret = app.run (args);
        // 清理 BinaryConverter 复用的临时基目录, 防止 /tmp 下泄漏
        BinaryConverter.cleanup_temp_dir ();
        return ret;
    }
}
