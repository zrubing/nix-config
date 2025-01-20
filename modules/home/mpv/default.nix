{ config, pkgs, ... }: {
  programs.mpv = {
    bindings = {
      "ctrl+[" = ''af set lavfi="pan=1c|c0=c0"'';
      "ctrl+]" = ''af set lavfi="pan=1c|c0=c1"'';
    };
    scripts = [ pkgs.mpvScripts.mpris ];
    config = {
      idle = "yes";
      keep-open = "yes";
      force-window = "yes";
      border = "no";

      autofit-larger = "1280x720";
      pause = "yes";

      alang = "jpn,jp,ita,it,eng,en";
      slang = "eng,en,ita,it";

      ytdl-format = "best";

      sub-border-size = "2";
      sub-font-size = "45";

      screenshot-template = "%f %P";
      screenshot-directory =
        "${config.xdg.userDirs.pictures}/Screenshots/Video";
    };
  };
}
