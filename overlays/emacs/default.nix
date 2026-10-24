{ inputs, ... }:
final: prev:
  if (prev ? lib) && (prev.lib ? composeManyExtensions) then
    inputs.emacs-overlay.overlay final prev
  else
    { }
