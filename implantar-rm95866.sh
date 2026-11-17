#!/bin/bash
# Projeto: DroneVision
# RM: 95866
# Objetivo: criar infraestrutura + deploy no Azure App Service (Linux/Python 3.11)
# Execucao: Azure Cloud Shell (Bash), na raiz deste repositorio.

set -euo pipefail

RM="95866"
PROJETO="dronevision"
LOCAL="eastus"
RG="rg-${PROJETO}-rm${RM}"
AIV="aiv-${PROJETO}-rm${RM}"
PLAN="plan-${PROJETO}-rm${RM}"
APP="app-${PROJETO}-rm${RM}"
REPO_URL="https://github.com/Guido-AlvaroPC/dronevision-rm95866.git"
VISION_SKU="S1"
# VISION_SKU="F0"  # opcao alternativa: Free Tier (limitada a 1 por assinatura)
PLAN_SKU="B1"
# PLAN_SKU="F1"  # fallback para assinatura academica sem cota de B1
PLAN_LOCATION="${LOCAL}"

TMP_DIR="$(mktemp -d)"
ZIP_PATH="${TMP_DIR}/app.zip"
HEALTH_TMP="${TMP_DIR}/health.json"

limpeza() {
  rm -rf "${TMP_DIR}"
}
trap limpeza EXIT

passo() {
  local numero="$1"
  local mensagem="$2"
  echo
  echo "[${numero}/7] ${mensagem}"
}

if ! az account show --output none >/dev/null 2>&1; then
  echo "Erro: sessao Azure nao encontrada. Abra o Azure Cloud Shell em modo Bash."
  exit 1
fi

passo 1 "Registrando provedores (idempotente)"
for provedor in Microsoft.CognitiveServices Microsoft.Web; do
  estado="$(az provider show --namespace "${provedor}" --query registrationState -o tsv 2>/dev/null || true)"
  if [[ "${estado}" != "Registered" ]]; then
    echo "Registrando ${provedor}..."
    az provider register --namespace "${provedor}" --wait >/dev/null
  else
    echo "${provedor} ja registrado."
  fi
done

passo 2 "Criando Resource Group ${RG}"
if az group exists --name "${RG}" | grep -qi true; then
  echo "Resource Group ja existe. Reutilizando."
else
  az group create --name "${RG}" --location "${LOCAL}" --output table
fi

passo 3 "Criando/reutilizando Azure AI Vision ${AIV}"
if az cognitiveservices account show --name "${AIV}" --resource-group "${RG}" --query name -o tsv >/dev/null 2>&1; then
  echo "Recurso Azure AI Vision ja existe. Reutilizando."
else
  set +e
  AIV_CREATE_OUTPUT="$(az cognitiveservices account create \
    --name "${AIV}" \
    --resource-group "${RG}" \
    --location "${LOCAL}" \
    --kind ComputerVision \
    --sku "${VISION_SKU}" \
    --custom-domain "${AIV}" \
    --yes 2>&1)"
  AIV_CREATE_CODE=$?
  set -e

  if [[ ${AIV_CREATE_CODE} -ne 0 ]]; then
    echo "${AIV_CREATE_OUTPUT}" >&2
    echo "Erro ao criar Azure AI Vision. Verifique cota/SKU da assinatura."
    echo "Dica: troque VISION_SKU para F0 se sua assinatura permitir."
    exit ${AIV_CREATE_CODE}
  fi
  echo "${AIV_CREATE_OUTPUT}"
fi

VISION_ENDPOINT="$(az cognitiveservices account show \
  --name "${AIV}" \
  --resource-group "${RG}" \
  --query properties.endpoint -o tsv)"
VISION_KEY="$(az cognitiveservices account keys list \
  --name "${AIV}" \
  --resource-group "${RG}" \
  --query key1 -o tsv)"

if [[ -z "${VISION_ENDPOINT}" || -z "${VISION_KEY}" ]]; then
  echo "Erro: nao foi possivel obter endpoint/chave do Azure AI Vision."
  exit 1
fi

passo 4 "Criando/reutilizando App Service Plan ${PLAN}"
if az appservice plan show --name "${PLAN}" --resource-group "${RG}" --query name -o tsv >/dev/null 2>&1; then
  echo "App Service Plan ja existe. Reutilizando."
else
  # Assinaturas academicas da FIAP costumam ter cota 0 de B1 em eastus.
  # Tenta B1 na regiao pedida, depois B1 em westus2 e, por ultimo, F1 em westus2.
  PLAN_CRIADO=0
  for tentativa in "B1:${LOCAL}" "B1:westus2" "F1:westus2"; do
    sku_tentativa="${tentativa%%:*}"
    loc_tentativa="${tentativa##*:}"
    echo "Tentando criar o plano Linux ${sku_tentativa} em ${loc_tentativa}..."
    set +e
    PLAN_CREATE_OUTPUT="$(az appservice plan create \
      --name "${PLAN}" \
      --resource-group "${RG}" \
      --location "${loc_tentativa}" \
      --is-linux \
      --sku "${sku_tentativa}" \
      --output table 2>&1)"
    PLAN_CREATE_CODE=$?
    set -e

    if [[ ${PLAN_CREATE_CODE} -eq 0 ]]; then
      PLAN_SKU="${sku_tentativa}"
      PLAN_LOCATION="${loc_tentativa}"
      PLAN_CRIADO=1
      echo "${PLAN_CREATE_OUTPUT}"
      echo "Plano criado: ${PLAN} (${PLAN_SKU}, ${PLAN_LOCATION})."
      break
    fi

    echo "${PLAN_CREATE_OUTPUT}"
    echo "Cota/SKU indisponivel para ${sku_tentativa} em ${loc_tentativa}. Tentando alternativa..."
  done

  if [[ ${PLAN_CRIADO} -ne 1 ]]; then
    echo "Erro: nao foi possivel criar o App Service Plan ${PLAN}."
    echo "Sua assinatura nao tem cota para B1/F1 nas regioes tentadas."
    echo "No Portal, abra Quotas (App Service) ou tente outra assinatura."
    exit 1
  fi
fi

passo 5 "Criando Web App ${APP} e configurando App Settings"
if az webapp show --name "${APP}" --resource-group "${RG}" --query name -o tsv >/dev/null 2>&1; then
  echo "Web App ja existe no Resource Group. Reutilizando."
else
  set +e
  WEBAPP_CREATE_OUTPUT="$(az webapp create \
    --name "${APP}" \
    --resource-group "${RG}" \
    --plan "${PLAN}" \
    --runtime "PYTHON:3.11" 2>&1)"
  WEBAPP_CREATE_CODE=$?
  set -e

  if [[ ${WEBAPP_CREATE_CODE} -ne 0 ]]; then
    echo "${WEBAPP_CREATE_OUTPUT}" >&2
    if [[ "${WEBAPP_CREATE_OUTPUT,,}" == *"already"* || "${WEBAPP_CREATE_OUTPUT,,}" == *"not available"* || "${WEBAPP_CREATE_OUTPUT,,}" == *"hostname"* ]]; then
      echo "Erro claro: o nome global do Web App (${APP}) nao esta disponivel."
      echo "Mantenha o padrao exigido e tente novamente em outra assinatura/tenant."
    fi
    exit ${WEBAPP_CREATE_CODE}
  fi
  echo "${WEBAPP_CREATE_OUTPUT}"
fi

az webapp config appsettings set \
  --resource-group "${RG}" \
  --name "${APP}" \
  --settings \
    VISION_ENDPOINT="${VISION_ENDPOINT}" \
    VISION_KEY="${VISION_KEY}" \
    SCM_DO_BUILD_DURING_DEPLOYMENT=true >/dev/null

az webapp config set \
  --resource-group "${RG}" \
  --name "${APP}" \
  --startup-file "gunicorn --bind=0.0.0.0 --timeout 120 app:app" >/dev/null

passo 6 "Fazendo deploy via ZIP (clone do GitHub + az webapp deploy)"
echo "Clonando repositorio em pasta temporaria..."
git clone "${REPO_URL}" "${TMP_DIR}/repo" >/dev/null

if [[ ! -d "${TMP_DIR}/repo/app" ]]; then
  echo "Erro: a pasta app/ nao foi encontrada no repositorio clonado."
  exit 1
fi

pushd "${TMP_DIR}/repo/app" >/dev/null
zip -r "${ZIP_PATH}" . >/dev/null
popd >/dev/null

az webapp deploy \
  --resource-group "${RG}" \
  --name "${APP}" \
  --src-path "${ZIP_PATH}" \
  --type zip \
  --output table

# Alternativa (nao usada aqui): az webapp up

passo 7 "Validando aplicacao publicada"
APP_URL="https://${APP}.azurewebsites.net"
HEALTH_URL="${APP_URL}/health"
echo "URL publica: ${APP_URL}"
echo "Testando endpoint de saude: ${HEALTH_URL}"

SAUDE_OK=0
for tentativa in {1..12}; do
  if curl -fsS --max-time 20 "${HEALTH_URL}" > "${HEALTH_TMP}"; then
    SAUDE_OK=1
    echo "Aplicacao respondeu no /health (tentativa ${tentativa})."
    cat "${HEALTH_TMP}"
    echo
    break
  fi
  echo "Aguardando subida da aplicacao... tentativa ${tentativa}/12"
  sleep 10
done

if [[ ${SAUDE_OK} -ne 1 ]]; then
  echo "Aviso: o /health ainda nao respondeu dentro do tempo esperado."
  echo "Verifique logs com: az webapp log tail --name ${APP} --resource-group ${RG}"
fi

echo
echo "Deploy finalizado."
echo "Resource Group: ${RG}"
echo "Azure AI Vision: ${AIV}"
echo "App Service Plan: ${PLAN} (${PLAN_SKU}, ${PLAN_LOCATION})"
echo "Web App: ${APP}"
echo "URL: ${APP_URL}"
