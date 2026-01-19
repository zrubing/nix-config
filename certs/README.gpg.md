cat rsa_private | nix-shell -p ssh-to-pgp --run "ssh-to-pgp -private-key" | gpg --import
cat rsa_private | nix-shell -p ssh-to-pgp --run "ssh-to-pgp" | gpg --import
