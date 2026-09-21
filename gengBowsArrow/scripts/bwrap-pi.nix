{ pkgs, localPkgs, ... }:
pkgs.writeShellScript "pi-bwrapped" ''
${localPkgs.scripts.bwrap-wpath}/bin/bwrap-wpath \
	--dev /dev \
	--proc /proc \
	--tmpfs /tmp \
	--setenv TMPDIR /tmp \
	--ro-bind /usr /usr \
	--ro-bind /etc /etc \
	--ro-bind /bin /bin \
	--ro-bind /run/secrets/keys/openrouter /run/secrets/keys/openrouter \
	--bind $HOME/.pi $HOME/.pi \
	--bind $PWD $PWD \
	pi "read and execute $PWD/instructions.txt"
''
