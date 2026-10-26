#!/usr/bin/env bash
# Publishes the Relevé landing page on GitHub Pages (free plan).
#
# First run:  creates a public GitHub repository, enables Pages with the
#             GitHub Actions workflow in .github/workflows/deploy.yml and
#             publishes the site.
# Later runs: commits any local changes and publishes them again.
#
# Usage: ./publicar.sh [repository-name]   (default: releve)
# Requires: git and the GitHub CLI (gh) logged in (gh auth login).

set -euo pipefail

cd "$(dirname "$0")"

REPO_NAME="${1:-releve}"
BRANCH="main"
WORKFLOW="deploy.yml"

say()  { printf '\n\033[1;35m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mError: %s\033[0m\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------------
# 1. Requirements
# ------------------------------------------------------------------
command -v git >/dev/null 2>&1 || fail "git no está instalado."
command -v gh  >/dev/null 2>&1 || fail "GitHub CLI no está instalado. Instálalo con: brew install gh"
gh auth status >/dev/null 2>&1 || fail "No has iniciado sesión en GitHub. Ejecuta: gh auth login"
[ -f index.html ] && [ -f 404.html ] && [ -f ".github/workflows/$WORKFLOW" ] \
  || fail "Faltan archivos del sitio (index.html, 404.html o el workflow)."

OWNER="$(gh api user --jq .login)"
say "Cuenta de GitHub: $OWNER  |  Repositorio: $OWNER/$REPO_NAME"

# ------------------------------------------------------------------
# 2. Local git repository
# ------------------------------------------------------------------
if [ ! -d .git ]; then
  say "Inicializando repositorio local..."
  git init -q -b "$BRANCH"
fi
if ! git rev-parse HEAD >/dev/null 2>&1; then
  git symbolic-ref HEAD "refs/heads/$BRANCH"
elif [ "$(git symbolic-ref --short HEAD 2>/dev/null || true)" != "$BRANCH" ]; then
  fail "Estás en otra rama. Cambia a '$BRANCH' antes de publicar (git checkout $BRANCH)."
fi

if [ -z "$(git config user.name || true)" ]; then
  git config user.name "$OWNER"
fi
if [ -z "$(git config user.email || true)" ]; then
  git config user.email "$OWNER@users.noreply.github.com"
fi

# ------------------------------------------------------------------
# 3. Remote repository (public: Pages is free only for public repos)
# ------------------------------------------------------------------
if ! git remote get-url origin >/dev/null 2>&1; then
  if gh repo view "$OWNER/$REPO_NAME" >/dev/null 2>&1; then
    say "El repositorio ya existe en GitHub; conectándolo..."
  else
    printf '\nSe creará el repositorio PÚBLICO https://github.com/%s/%s\n' "$OWNER" "$REPO_NAME"
    read -r -p "¿Continuar? (s/N) " answer
    case "$answer" in s|S|si|SI|sí|Sí) ;; *) fail "Cancelado por el usuario." ;; esac
    gh repo create "$OWNER/$REPO_NAME" --public \
      --description "Landing page de Relevé, estudio de yoga, ballet, ballet fit y fit" >/dev/null
  fi
  git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
fi

# ------------------------------------------------------------------
# 4. Commit local changes
# ------------------------------------------------------------------
git add -A
if ! git diff --cached --quiet; then
  git commit -q -m "Actualiza sitio $(date '+%Y-%m-%d %H:%M')"
  say "Cambios guardados en un commit."
elif ! git rev-parse HEAD >/dev/null 2>&1; then
  fail "No hay archivos para publicar."
else
  say "No hay cambios nuevos; se vuelve a publicar la versión actual."
fi

# ------------------------------------------------------------------
# 5. Enable GitHub Pages with GitHub Actions as the source
# ------------------------------------------------------------------
PAGES_ERROR=""
enable_pages() {
  local current
  current="$(gh api "repos/$OWNER/$REPO_NAME/pages" --jq .build_type 2>/dev/null || true)"
  if [ -z "$current" ]; then
    PAGES_ERROR="$(gh api -X POST "repos/$OWNER/$REPO_NAME/pages" -f build_type=workflow 2>&1 >/dev/null)" || return 1
  elif [ "$current" != "workflow" ]; then
    PAGES_ERROR="$(gh api -X PUT "repos/$OWNER/$REPO_NAME/pages" -f build_type=workflow 2>&1 >/dev/null)" || return 1
  fi
}

# A freshly created repository can take a few seconds before GitHub
# accepts the Pages settings, so retry with a short wait.
enable_pages_with_retry() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    enable_pages && return 0
    sleep 5
  done
  return 1
}

PAGES_READY=0
if enable_pages; then PAGES_READY=1; fi

# ------------------------------------------------------------------
# 6. Push and wait for the deployment
# ------------------------------------------------------------------
say "Subiendo a GitHub..."
git push -q -u origin "$BRANCH"
SHA="$(git rev-parse HEAD)"

if [ "$PAGES_READY" -eq 0 ]; then
  # A brand-new empty repository may refuse Pages until it has a commit
  say "Activando GitHub Pages..."
  enable_pages_with_retry || fail "No se pudo activar GitHub Pages. Respuesta de GitHub: ${PAGES_ERROR:-sin detalle}"
  sleep 3
  gh workflow run "$WORKFLOW" --ref "$BRANCH" >/dev/null
fi

say "Esperando a que GitHub Actions publique el sitio..."
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID="$(gh run list --workflow "$WORKFLOW" --branch "$BRANCH" --limit 5 \
    --json databaseId,headSha,createdAt \
    --jq "[.[] | select(.headSha == \"$SHA\")] | sort_by(.createdAt) | last | .databaseId // empty")"
  [ -n "$RUN_ID" ] && break
  sleep 2
done
[ -n "$RUN_ID" ] || fail "No apareció la ejecución del workflow. Revisa la pestaña Actions del repositorio."

if ! gh run watch "$RUN_ID" --exit-status; then
  # The push-triggered run can fail if Pages was enabled a moment later; retry once
  say "La primera ejecución falló; reintentando..."
  gh run rerun "$RUN_ID" >/dev/null
  sleep 5
  gh run watch "$RUN_ID" --exit-status || fail "La publicación falló. Detalles: gh run view $RUN_ID --log-failed"
fi

URL="$(gh api "repos/$OWNER/$REPO_NAME/pages" --jq .html_url)"
say "Listo. Tu sitio está publicado en: $URL"
echo "Puede tardar uno o dos minutos en reflejarse la primera vez."
