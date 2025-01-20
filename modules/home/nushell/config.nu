$env.config = {
  show_banner: false
  keybindings: [
    {
      name: zoxide
      modifier: control
      keycode: char_z
      mode: [emacs, vi_normal, vi_insert]
      event: { send: executehostcommand cmd: "__zoxide_zi" }
    }
  ]
}

alias l = ls
