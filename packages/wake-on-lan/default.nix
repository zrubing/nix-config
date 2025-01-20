{ writeScriptBin, ruby }:
writeScriptBin "wake-on-lan" ''
  #!${ruby}/bin/ruby
  ${builtins.readFile ./wake-on-lan.rb}
''
