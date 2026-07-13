#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/FreeFlowApp/Resources/models"
MODEL_WORK="$ROOT_DIR/FreeFlowApp/.model-work"
MODEL_VENV="$MODEL_WORK/venv"
MODEL_PYTHON="$MODEL_VENV/bin/python3"
MODEL_HF="$MODEL_VENV/bin/hf"
ADAPTER_SOURCE="$ROOT_DIR/FreeFlowApp/ModelSources/qwen3-0.6b-4bit-polish-adapter"
ADAPTER_NAME="qwen3-0.6b-4bit-polish-adapter"
NEMOTRON_NAME="nemotron-speech-streaming-en-0.6b-coreml"
QWEN_NAME="qwen3-0.6b-4bit"
NEMOTRON_REPO="mrinalwadhwa/nemotron-speech-streaming-en-0.6b-coreml"
NEMOTRON_REV="c812c6604ec09800084fa8c38bacb6748239c48c"
QWEN_REPO="mrinalwadhwa/Qwen3-0.6B-4bit"
QWEN_REV="44c9f61dea041165b988662ba914dbfef0e0d096"
QWEN_FILES=(
    added_tokens.json
    config.json
    merges.txt
    model.safetensors
    model.safetensors.index.json
    special_tokens_map.json
    tokenizer.json
    tokenizer_config.json
    vocab.json
)

checksums() {
    cat <<'EOF'
bca0e343fa0d698de8bdb22c66fd377b79104f606b1bfffc90931fe2161029b8  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/decoder.mlmodelc/analytics/coremldata.bin
4d0549ac72a38abdcbe7927f2b7d488386d6b96f1f5e837d93ba9e379de04f4e  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/decoder.mlmodelc/coremldata.bin
8298f16d3926565b77732b549fa9c64fedebb2e5a29a76e33d0b2e970e93ae69  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/decoder.mlmodelc/model.mil
d9758e49f9b2b9a0462c933256663d4174209739e62f0ddc14e4147bc50e7818  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/decoder.mlmodelc/weights/weight.bin
ef51dbab5c6ce310ce1a537538a4df6b88f13ad5c45c0acaddca055503896daa  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/analytics/coremldata.bin
864a357ae2eb7d6b38ced73d5f23c908096a256516afa498c6730778767ec404  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/coremldata.bin
4b903ee4f401d81add07d1252192a486bd07154174818902f03bca38b2f293f6  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/model.mil
8ced31411f7903eaec52de85e94c7847228f3e44028d8f0040800e5603943a40  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/weights/weight.bin
478804308534c7f9cab1030aa9ce19ddf672fcd15deba633fe3ed5da8f53b103  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/joint.mlmodelc/analytics/coremldata.bin
46363626fd89730ade6e6461e8be808c7fade198fb0df63db83fb00ed033abb2  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/joint.mlmodelc/coremldata.bin
73bcc51b58ff73c7620e31a2c32dc5ef4939e8ec2a77ec22242303422bfafba4  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/joint.mlmodelc/model.mil
d1d45514a91da39f24e264712a9f8b5a2a90e9cbce04bad3f3f74242bea106d5  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/joint.mlmodelc/weights/weight.bin
e8d93e5afa1e5c87257f6e31a5c336058eeba7d6cacd36ba80fbf9758c3916dc  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/metadata.json
6f7478ac6121c7738735bf8cf630fc3f235a6039ae84d49bdd4b5fa077436ebb  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/preprocessor.mlmodelc/analytics/coremldata.bin
92a11fb7f8e6f61a15d29437ff1d6cabc077519fc1a9be68354f8fb339fbfbd7  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/preprocessor.mlmodelc/coremldata.bin
24a26b36944798b1884048ae3fb6ae66b16db0f701d977b9ee3bc276c2f90549  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/preprocessor.mlmodelc/model.mil
297514e2b211d14b0e53cb97193d679bb89ead98d28e578f3f1d049ddbcc36b3  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/preprocessor.mlmodelc/weights/weight.bin
a87b5b8a0e0a989fa7db3121f279ce6af70e337feb55ab553b8d0658db70b9d3  nemotron-speech-streaming-en-0.6b-coreml/nemotron_coreml_560ms/tokenizer.json
c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680  qwen3-0.6b-4bit/added_tokens.json
15d3ac26c043ae477273ed5802ee0f0b33bb14f18c9d3dd70910c02d906e3f1f  qwen3-0.6b-4bit/config.json
8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5  qwen3-0.6b-4bit/merges.txt
392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2  qwen3-0.6b-4bit/model.safetensors
7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb  qwen3-0.6b-4bit/model.safetensors.index.json
76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd  qwen3-0.6b-4bit/special_tokens_map.json
aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4  qwen3-0.6b-4bit/tokenizer.json
253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0  qwen3-0.6b-4bit/tokenizer_config.json
ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910  qwen3-0.6b-4bit/vocab.json
EOF
}

verify() {
    local models_dir="$1"
    local expected actual

    if [[ ! -d "$models_dir" ]]; then
        echo "ERROR: model pack is missing at $models_dir" >&2
        return 1
    fi
    if [[ -n "$(find "$models_dir" ! -type d ! -type f -print -quit)" ]]; then
        echo "ERROR: model pack contains a symlink or non-file entry" >&2
        return 1
    fi

    expected=$(($(checksums | wc -l | tr -d ' ') + 2))
    actual=$(find "$models_dir" -type f | wc -l | tr -d ' ')
    if [[ "$actual" -ne "$expected" ]]; then
        echo "ERROR: model pack has $actual files, expected $expected" >&2
        return 1
    fi

    (
        cd "$models_dir"
        checksums | shasum -a 256 -c -
    )
    cmp "$ADAPTER_SOURCE/adapter_config.json" \
        "$models_dir/$ADAPTER_NAME/adapter_config.json"
    cmp "$ADAPTER_SOURCE/adapters.safetensors" \
        "$models_dir/$ADAPTER_NAME/adapters.safetensors"
}

download() {
    local python="${PYTHON:-python3}"

    if [[ -L "$MODEL_WORK" || ( -e "$MODEL_WORK" && ! -d "$MODEL_WORK" ) ]]; then
        echo "ERROR: model work path must be a real directory: $MODEL_WORK" >&2
        return 1
    fi
    mkdir -p "$MODEL_WORK"
    rm -rf "$MODEL_VENV"
    "$python" -m venv "$MODEL_VENV"
    # huggingface-hub 1.11.0 imports Click without declaring it.
    "$MODEL_PYTHON" -m pip install --disable-pip-version-check \
        'huggingface-hub==1.11.0' 'click==8.3.1'

    rm -rf "$MODEL_DIR"
    mkdir -p "$MODEL_DIR"
    "$MODEL_HF" download "$NEMOTRON_REPO" nemotron_coreml_560ms/ \
        --revision "$NEMOTRON_REV" --local-dir "$MODEL_DIR/$NEMOTRON_NAME"
    "$MODEL_HF" download "$QWEN_REPO" "${QWEN_FILES[@]}" \
        --revision "$QWEN_REV" --local-dir "$MODEL_DIR/$QWEN_NAME"
    rm -rf "$MODEL_DIR/$NEMOTRON_NAME/.cache" "$MODEL_DIR/$QWEN_NAME/.cache" \
        "$MODEL_DIR/$NEMOTRON_NAME/nemotron_coreml_560ms/decoder_joint.mlmodelc"
    cp -R "$ADAPTER_SOURCE" "$MODEL_DIR/$ADAPTER_NAME"
    verify "$MODEL_DIR"
}

case "${1:-}" in
    download)
        download
        ;;
    verify)
        verify "${2:-$MODEL_DIR}"
        ;;
    *)
        echo "usage: $0 {download|verify [models-directory]}" >&2
        exit 2
        ;;
esac
