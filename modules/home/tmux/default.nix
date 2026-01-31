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

        # --- 快捷键 ---

        # 使用 PREFIX | 和 PREFIX - 进行垂直/水平分割
        bind | split-window -h -c "#{pane_current_path}"
        bind - split-window -v -c "#{pane_current_path}"

        # 使用 PREFIX h/j/k/l 切换面板（Vim 风格）
        bind h select-pane -L
        bind j select-pane -D
        bind k select-pane -U
        bind l select-pane -R

        # 使用 PREFIX H/J/K/L 调整面板大小
        bind -r H resize-pane -L 5
        bind -r J resize-pane -D 5
        bind -r K resize-pane -U 5
        bind -r L resize-pane -R 5

        # 使用 PREFIX Ctrl+h/l 切换窗口
        bind -r C-h select-window -t :-
        bind -r C-l select-window -t :+

        # 使用 PREFIX q 可视化选择面板
        bind q display-panes -d 0

        # 复制模式使用 Vi 键位
        setw -g mode-keys vi

        # 复制模式下的快捷键
        bind -T copy-mode-vi v send-keys -X begin-selection
        bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
        bind -T copy-mode-vi r send-keys -X rectangle-toggle

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
