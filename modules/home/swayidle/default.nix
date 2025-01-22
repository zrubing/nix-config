{ pkgs, ... }:
let
  swaylock = "${pkgs.swaylock-effects}/bin/swaylock";
  power-off-monitors = "${pkgs.niri}/bin/niri msg action power-off-monitors";
in
{
  services.swayidle = {
    extraArgs = [
      "-d"
    ];
    events = [
      {
        event = "before-sleep";
        command = swaylock;
      }
      {
        event = "lock";
        command = swaylock;
      }
    ];
    timeouts = [
      {
        timeout = 10 * 60;
        command = power-off-monitors;
      }
      {
        timeout = 10 * 60 + 5;
        command = "${swaylock} --daemonize --debug";
      }
      {
        timeout = 10;
        command = "${pkgs.procps}/bin/pgrep -x swaylock && ${power-off-monitors}";
      }
    ];
  };
}
