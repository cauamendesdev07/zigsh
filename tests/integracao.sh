#!/usr/bin/env bash
# Testes de integração do zigsh. Executados por `zig build test`.
set -euo pipefail

zigsh="${1:?uso: integracao.sh <caminho-do-zigsh>}"
if [[ "$zigsh" != /* ]]; then
    zigsh="$(cd "$(dirname "$zigsh")" && pwd)/$(basename "$zigsh")"
fi
raiz="$(mktemp -d /tmp/zigsh-integracao.XXXXXX)"
trap 'rm -rf "$raiz"' EXIT

falhar() {
    printf 'FALHOU: %s\n' "$*" >&2
    exit 1
}

executar() {
    (cd "$raiz" && "$zigsh")
}

contem() {
    local saida="$1"
    local trecho="$2"
    local nome="$3"

    [[ "$saida" == *"$trecho"* ]] || falhar "$nome: saída não contém '$trecho'"
}

mkdir -p "$raiz/sub"
printf 'linha um\ntermo aqui\nlinha tres\n' > "$raiz/entrada.txt"

saida="$(printf 'pwd\n\n/bin/echo ola\nhelp\n' | executar)"
contem "$saida" "zigsh [$raiz]> " "prompt"
contem "$saida" "$raiz" "pwd"
contem "$saida" "ola" "comando externo"
contem "$saida" "Comandos internos disponíveis:" "help"
contem "$saida" "exit [codigo]" "help exit"

saida="$(printf 'cd sub\npwd\ncd ..\npwd\n' | executar)"
contem "$saida" "zigsh [$raiz/sub]> " "prompt após cd"
contem "$saida" "$raiz/sub" "pwd dentro do subdiretório"
contem "$saida" "zigsh [$raiz]> " "prompt após voltar"

saida="$(printf 'cd nao-existe\n' | executar)"
contem "$saida" "zigsh: cd: não foi possível acessar 'nao-existe'" "erro do cd"

saida="$(printf '/bin/echo conteudo > saida.txt\n/bin/cat < saida.txt\n' | executar)"
contem "$saida" "conteudo" "redirecionamento de stdout e stdin"
[[ -f "$raiz/saida.txt" ]] || falhar "arquivo de saída não foi criado"
/bin/grep -qx 'conteudo' "$raiz/saida.txt" || falhar "conteúdo do arquivo de saída"

saida="$(printf '/bin/ls /nao-existe 2> erros.txt\n/bin/cat erros.txt\n' | executar)"
[[ -s "$raiz/erros.txt" ]] || falhar "arquivo de stderr não foi criado"
erro_redirecionado="$(head -n 1 "$raiz/erros.txt")"
[[ -n "$erro_redirecionado" ]] || falhar "arquivo de stderr está vazio"
contem "$saida" "$erro_redirecionado" "redirecionamento de stderr"

saida="$(printf '/bin/cat entrada.txt | /bin/grep termo\n' | executar)"
contem "$saida" "termo aqui" "pipeline simples"

printf '/bin/cat < entrada.txt | /bin/grep termo | /usr/bin/wc -l > contagem.txt\n' | executar > /dev/null
[[ "$(tr -d '[:space:]' < "$raiz/contagem.txt")" == "1" ]] || falhar "pipeline com entrada e três comandos"

saida="$(printf '/bin/cat entrada.txt | /bin/grep termo > resultado.txt\n/bin/cat resultado.txt\n' | executar)"
/bin/grep -qx 'termo aqui' "$raiz/resultado.txt" || falhar "redirecionamento da pipeline"

saida="$(printf '/bin/echo a | \n' | executar)"
contem "$saida" "zigsh: pipeline com comando vazio" "pipeline com comando vazio"

printf '/bin/sleep 2 &\n/bin/echo imediato\n' > "$raiz/fundo.txt"
inicio="$(date +%s%N)"
(cd "$raiz" && timeout 5 "$zigsh" < fundo.txt > fundo.saida 2>&1) || falhar "background travou"
fim="$(date +%s%N)"
decorrido_ms=$(( (fim - inicio) / 1000000 ))
[[ "$decorrido_ms" -lt 1500 ]] || falhar "background demorou ${decorrido_ms}ms"
/bin/grep -q '\[Processo disparado em segundo plano\]' "$raiz/fundo.saida" || falhar "mensagem de background"
/bin/grep -q 'imediato' "$raiz/fundo.saida" || falhar "comando após background"

printf '/bin/sleep 2 | /bin/cat &\n/bin/echo imediato2\n' > "$raiz/fundo-pipeline.txt"
inicio="$(date +%s%N)"
(cd "$raiz" && timeout 5 "$zigsh" < fundo-pipeline.txt > fundo-pipeline.saida 2>&1) || falhar "pipeline em background travou"
fim="$(date +%s%N)"
decorrido_ms=$(( (fim - inicio) / 1000000 ))
[[ "$decorrido_ms" -lt 1500 ]] || falhar "pipeline em background demorou ${decorrido_ms}ms"
/bin/grep -q '\[Processo disparado em segundo plano\]' "$raiz/fundo-pipeline.saida" || falhar "mensagem de pipeline em background"
/bin/grep -q 'imediato2' "$raiz/fundo-pipeline.saida" || falhar "comando após pipeline em background"

saida="$({
    printf '/usr/bin/yes | /usr/bin/head -n 1\n'
} | timeout 5 bash -c 'cd "$1" && "$2"' _ "$raiz" "$zigsh" 2>&1)" || falhar "pipeline com consumidor antecipado travou"
contem "$saida" "y" "pipeline com consumidor antecipado"

head -c 1048576 /dev/zero > "$raiz/grande.bin"
saida="$(printf '/bin/cat grande.bin | /usr/bin/wc -c\n' | executar)"
contem "$saida" "1048576" "pipeline com 1 MiB"

set +e
printf 'exit 7\n' | (cd "$raiz" && "$zigsh") > "$raiz/saida-exit.txt" 2>&1
status=$?
set -e
[[ "$status" -eq 7 ]] || falhar "exit 7 retornou $status"

saida="$(printf 'exit abc\nexit 1 2\nexit\n' | executar)"
contem "$saida" "zigsh: exit: código inválido" "exit inválido"
contem "$saida" "Uso: exit [codigo]" "exit com argumentos demais"

printf 'Testes de integração do zigsh: OK\n'
