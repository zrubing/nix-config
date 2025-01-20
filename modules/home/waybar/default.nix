{
  programs.waybar = {
    systemd.enable = true;
    settings = [{
      layer = "top";
      position = "bottom";
      spacing = 0;
      modules-left = [ "niri/workspaces" "wlr/taskbar" ];
      modules-right =
        [ "tray" "cpu" "memory" "network" "pulseaudio" "battery" "clock" ];
      "niri/workspaces" = {
        format = "{index}";
        on-click = "activate";
      };
      "wlr/taskbar" = {
        format = "{icon}";
        tooltip-format = "{title}";
        icon-size = 14;
        on-click = "activate";
      };
      tray = {
        # icon-size = 16;
        spacing = 10;
      };
      clock = {
        timezone = "Asia/Shanghai";
        tooltip-format = ''
          <big>{:%Y %B}</big>
          <tt><small>{calendar}</small></tt>'';
        format-alt = "{:%Y-%m-%d}";
      };
      cpu = {
        format = "{usage}% ";
        tooltip = false;
      };
      memory = { format = "{}% "; };
      battery = {
        states = {
          warning = 30;
          critical = 15;
        };
        format = "{capacity}% {icon}";
        format-charging = "{capacity}% 󰂄";
        format-plugged = "{capacity}% 󱟢";
        format-alt = "{time} {icon}";
        # format-icons = [ "" "" "" "" "" ];
        format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
      };
      network = {
        format-wifi = "{essid} ({signalStrength}%) ";
        format-ethernet = "{ipaddr}/{cidr} 󰈀";
        tooltip-format = "{ifname} via {gwaddr} 󰈀";
        format-linked = "{ifname} (No IP) 󰈀";
        format-disconnected = "Disconnected ⚠";
        format-alt = "{ifname}: {ipaddr}/{cidr}";
      };
      pulseaudio = {
        format = "{volume}% {icon} {format_source}";
        format-bluetooth = "{volume}% {icon} {format_source}";
        format-bluetooth-muted = " {icon} {format_source}";
        format-muted = " {format_source}";
        format-source = "{volume}% ";
        format-source-muted = "";
        format-icons = {
          headphone = "";
          hands-free = "󰋎";
          headset = "󰋎";
          phone = "";
          portable = "";
          car = "";
          default = [ "" "" "" ];
        };
        # on-click = "pavucontrol";
      };
    }];
    style = ./style.css;
  };
}
