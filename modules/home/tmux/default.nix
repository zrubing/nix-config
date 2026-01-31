{
  lib,
  config,
  pkgs,
  namespace,
  inputs,
  ...
}:

let
  cfg = config.${namespace}.modules.tmux;
in
{
  options.${namespace}.modules.tmux = {
    enable = lib.mkEnableOption "tmux terminal multiplexer";
  };

  config = lib.mkIf cfg.enable {
    programs.tmux = {
      enable = true;

      # Ctrl+a 作为前缀键（更符合习惯，不与 Ctrl+b 冲突）
      shortcut = "a";

      # 256 色支持
      baseIndex = 1;
      escapeTime = 10;

      # 鼠标支持
      mouse = true;

      # 自定义配置
      extraConfig = ''
        # --- 状态栏 ---
        set -g status-position bottom
        set -g status-justify left
        set -g status-style 'bg=colour240 fg=white'
        set -g status-left '#[bg=colour236 fg=colour214] #S #[default] '
        set -g status-left-length 20
        set -g status-right '#[bg=colour236 fg=colour114] %H:%M #[default] #[bg=colour236 fg=colour174] %Y-%m-%d '
        set -g status-right-length 50

        # 窗口列表格式
        setw -g window-status-format ' #I:#W '
        setw -g window-status-current-format '#[bg=colour31 fg=white bold] #I:#W '

        # 窗口和面板编号从 1 开始
        set -g base-index 1
        setw -g pane-base-index 1

        # 自动重命名窗口
        setw -g automatic-rename on

        # 活动面板边框样式
        setw -g window-status-activity-style 'fg=white bg=colour31'

        # 面板边框
        set -g pane-border-style 'fg=colour244'
        set -g pane-active-border-style 'fg=colour214'

        # 命令行样式
        set -g message-command-style 'fg=white bg=colour236'
        set -g message-style 'fg=white bg=colour236 bold'

        # --- 快捷键 (Emacs 风格) ---
        # 参考: https://github.com/dakrone/eos

        # === 窗口分割 (Emacs C-x 风格) ===
        # C-x 2: 水平分割 (上下), C-x 3: 垂直分割 (左右)
        bind 2 split-window -v -c "#{pane_current_path}"
        bind 3 split-window -h -c "#{pane_current_path}"
        bind 0 kill-pane           # C-x 0: 关闭当前面板
        bind 1 break-pane          # C-x 1: 当前面板独占窗口

        # 同时保留直观的分割键
        bind | split-window -h -c "#{pane_current_path}"
        bind - split-window -v -c "#{pane_current_path}"

        # === 面板导航 (Emacs C-x o 风格) ===
        # 使用 o 轮换面板 (类似 Emacs C-x o)
        bind o select-pane -t :.+
        bind O select-pane -t :.-

        # 使用方向键导航 (配合 prefix)
        bind -r C-h select-pane -L
        bind -r C-j select-pane -D
        bind -r C-k select-pane -U
        bind -r C-l select-pane -R

        # === 面板大小调整 ===
        # 类似 Emacs 的 window-resizer
        bind -r H resize-pane -L 5
        bind -r J resize-pane -D 5
        bind -r K resize-pane -U 5
        bind -r L resize-pane -R 5

        # === 窗口切换 ===
        # C-f/C-b 前后切换 (Emacs 风格)
        bind -r C-f next-window
        bind -r C-b previous-window
        # C-a 切换到上一个窗口 (类似 Emacs C-x b)
        bind a last-window

        # === 面板管理 ===
        # @ 合并面板: 将其他窗口的面板拉到当前窗口
        bind @ command-prompt -p "join pane from:" "join-pane -s '%%'"
        # B 拆分面板: 将当前面板拆成新窗口
        bind B break-pane

        # === 同步模式 ===
        # e/E 切换所有面板同步输入 (类似 echo)
        bind e setw synchronize-panes on \; display "Sync: ON"
        bind E setw synchronize-panes off \; display "Sync: OFF"

        # === 可视化选择 ===
        bind q display-panes -d 0

        # === 复制模式 ===
        # 进入复制模式 (C-[ 或 Escape, 类似 Emacs)
        bind C-[ copy-mode
        bind Escape copy-mode

        # Emacs 键位
        setw -g mode-keys emacs

        # 复制操作 (Emacs 风格)
        bind -T copy-mode C-Space send-keys -X begin-selection    # C-SPC 开始选择
        bind -T copy-mode C-g send-keys -X cancel                 # C-g 取消
        bind -T copy-mode M-w send-keys -X copy-selection-and-cancel  # M-w 复制
        bind -T copy-mode C-w send-keys -X copy-selection-and-cancel  # C-w 也行

        # 粘贴 (Emacs C-y 风格)
        bind C-y paste-buffer

        # 选择缓冲区粘贴
        bind ] choose-buffer

        # === 其他 ===
        # r 重新加载配置
        bind r source-file ~/.config/tmux/tmux.conf \; display-message "Config reloaded"

        # c 新建窗口 (保持在当前路径)
        bind c new-window -c "#{pane_current_path}"

        # PREFIX r 重新加载配置
        bind r source-file ~/.config/tmux/tmux.conf \; display-message "Config reloaded"

        # PREFIX Ctrl+c 新建窗口（保持在当前路径）
        bind c new-window -c "#{pane_current_path}"

        # 根据窗口名自动设置状态栏颜色（ssh: 开头的窗口显示红色）
        # 使用 set (session级) 而非 set -g (全局)，避免被覆盖
        set-hook -g pane-focus-in 'if-shell -F "#{m:ssh:*,#{window_name}}" "set status-style bg=colour196,fg=white; refresh-client -S" "set status-style bg=colour240,fg=white; refresh-client -S"'
        set-hook -g window-renamed 'if-shell -F "#{m:ssh:*,#{window_name}}" "set status-style bg=colour196,fg=white; refresh-client -S" "set status-style bg=colour240,fg=white; refresh-client -S"'
        set-hook -g client-attached 'if-shell -F "#{m:ssh:*,#{window_name}}" "set status-style bg=colour196,fg=white; refresh-client -S" "set status-style bg=colour240,fg=white; refresh-client -S"'
        set-hook -g client-session-changed 'if-shell -F "#{m:ssh:*,#{window_name}}" "set status-style bg=colour196,fg=white; refresh-client -S" "set status-style bg=colour240,fg=white; refresh-client -S"'
      '';
    };

    # 安装 tmux
    home.packages = with pkgs; [
      tmux
    ];
  };
}
