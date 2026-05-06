{
  pkgs,
  inputs,
  system,
  namespace,
  ...
}:
{

  home.file.".lib/vue-language-tools".source = "${
    pkgs.vue-language-server
  }/lib/language-tools";

}
