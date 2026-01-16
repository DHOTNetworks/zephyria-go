         #!/bin/bash
# set -e # Allow failures to continue so we see which ones work

echo "Fetching zasm..."
zig fetch --save=zasm git+https://github.com/andrewrk/zasm

echo "Fetching zig-libp2p..."
zig fetch --save=libp2p git+https://github.com/MarcoPolo/zig-libp2p

echo "Fetching zig-msquic..."
zig fetch --save=msquic git+https://github.com/MarcoPolo/zig-msquic

echo "Fetching zig-eth-secp256k1..."
zig fetch --save=secp256k1 git+https://github.com/jsign/zig-eth-secp256k1

echo "Fetching blst-z..."
zig fetch --save=blst git+https://github.com/gballet/blst-z

echo "Fetching kzigg..."
zig fetch --save=kzigg git+https://github.com/spiral-ladder/kzigg

echo "Fetching ssz-z..."
zig fetch --save=ssz git+https://github.com/ChainSafe/ssz-z

echo "Fetching zig-rlp..."
zig fetch --save=rlp git+https://github.com/gballet/zig-rlp

echo "Done."
