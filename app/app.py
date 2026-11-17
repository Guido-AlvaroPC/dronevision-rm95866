"""Aplicacao DroneVision.

Projeto academico para analise de imagens com Azure AI Vision.
Entrega oficial: Azure App Service + Azure CLI (Cloud Shell).
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import requests
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 4 * 1024 * 1024  # 4 MB

ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".gif"}
ALLOWED_MIME_TYPES = {
    "image/jpeg",
    "image/jpg",
    "image/png",
    "image/bmp",
    "image/gif",
}

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("dronevision")


class VisionApiError(Exception):
    """Erro controlado para mapear falhas da API Vision em mensagens amigaveis."""

    def __init__(self, mensagem: str, status_code: int) -> None:
        super().__init__(mensagem)
        self.mensagem = mensagem
        self.status_code = status_code


def _json_erro(mensagem: str, status_code: int):
    return jsonify({"erro": mensagem}), status_code


def _assinatura_valida(imagem_bytes: bytes) -> bool:
    """Valida assinatura basica para evitar envio de arquivos nao-imagem."""
    if imagem_bytes.startswith(b"\xFF\xD8\xFF"):  # JPEG
        return True
    if imagem_bytes.startswith(b"\x89PNG\r\n\x1a\n"):  # PNG
        return True
    if imagem_bytes.startswith((b"GIF87a", b"GIF89a")):  # GIF
        return True
    if imagem_bytes.startswith(b"BM"):  # BMP
        return True
    return False


def _validar_e_ler_arquivo() -> bytes:
    if "imagem" not in request.files:
        raise VisionApiError("Selecione uma imagem antes de analisar.", 400)

    arquivo = request.files["imagem"]
    if not arquivo or arquivo.filename is None or arquivo.filename.strip() == "":
        raise VisionApiError("Nenhum arquivo foi enviado.", 400)

    nome_seguro = Path(arquivo.filename).name
    extensao = Path(nome_seguro).suffix.lower()
    if extensao not in ALLOWED_EXTENSIONS:
        raise VisionApiError(
            "Formato nao suportado. Envie JPG, PNG, BMP ou GIF.", 400
        )

    mime = (arquivo.mimetype or "").lower().strip()
    if mime and mime not in ALLOWED_MIME_TYPES:
        raise VisionApiError(
            "Tipo de arquivo invalido. Envie uma imagem JPG, PNG, BMP ou GIF.", 400
        )

    imagem_bytes = arquivo.read()
    if not imagem_bytes:
        raise VisionApiError("A imagem enviada esta vazia.", 400)
    if len(imagem_bytes) > app.config["MAX_CONTENT_LENGTH"]:
        raise VisionApiError("A imagem excede 4 MB. Envie um arquivo menor.", 413)
    if not _assinatura_valida(imagem_bytes):
        raise VisionApiError(
            "Nao foi possivel validar o arquivo como imagem suportada.", 400
        )

    return imagem_bytes


def _obter_config_vision() -> tuple[str, str]:
    endpoint = os.getenv("VISION_ENDPOINT", "").strip()
    key = os.getenv("VISION_KEY", "").strip()

    if not endpoint or not key:
        raise VisionApiError(
            "Servico de analise indisponivel: configuracao do Azure AI Vision ausente.",
            503,
        )

    return endpoint, key


def _chamar_vision(imagem_bytes: bytes, endpoint: str, key: str) -> dict[str, Any]:
    url = f"{endpoint.rstrip('/')}/vision/v3.2/analyze"
    params = {
        "visualFeatures": "Description,Tags,Objects",
        "language": "en",
    }
    headers = {
        "Ocp-Apim-Subscription-Key": key,
        "Content-Type": "application/octet-stream",
    }

    try:
        resposta = requests.post(
            url, params=params, headers=headers, data=imagem_bytes, timeout=30
        )
    except requests.Timeout as exc:
        logger.exception("Timeout ao chamar Azure AI Vision.")
        raise VisionApiError(
            "O servico de analise esta indisponivel no momento (timeout).", 503
        ) from exc
    except requests.ConnectionError as exc:
        logger.exception("Falha de conexao com Azure AI Vision.")
        raise VisionApiError(
            "Nao foi possivel conectar ao servico de analise. Tente novamente.",
            503,
        ) from exc

    if resposta.status_code == 400:
        raise VisionApiError(
            "A imagem foi considerada invalida pelo servico de visao.", 400
        )
    if resposta.status_code in (401, 403):
        logger.error("Falha de autenticacao com Azure AI Vision (status %s).", resposta.status_code)
        raise VisionApiError("Falha de autenticacao com o servico de analise.", 502)
    if resposta.status_code == 429:
        raise VisionApiError(
            "Limite de requisicoes atingido. Aguarde e tente novamente.", 429
        )
    if resposta.status_code == 503:
        raise VisionApiError(
            "Servico de analise indisponivel no momento (503).", 503
        )
    if resposta.status_code >= 500:
        raise VisionApiError(
            "Falha temporaria no servico de analise. Tente novamente em instantes.",
            503,
        )
    if not resposta.ok:
        logger.error(
            "Falha na chamada do Vision. Status: %s. Corpo: %s",
            resposta.status_code,
            resposta.text[:500],
        )
        raise VisionApiError("Falha na analise da imagem.", 502)

    try:
        return resposta.json()
    except ValueError as exc:
        logger.exception("Resposta JSON invalida da API Vision.")
        raise VisionApiError("Falha ao interpretar a resposta da analise.", 502) from exc


def _arredondar_confianca(valor: Any) -> float | None:
    if valor is None:
        return None
    try:
        return round(float(valor), 4)
    except (TypeError, ValueError):
        return None


def _normalizar_resultado(resposta_vision: dict[str, Any]) -> dict[str, Any]:
    descricao_raw = resposta_vision.get("description", {}) or {}
    captions = descricao_raw.get("captions", []) or []
    tags_descricao = descricao_raw.get("tags", []) or []
    tags_gerais = resposta_vision.get("tags", []) or []
    objetos_gerais = resposta_vision.get("objects", []) or []

    if captions:
        primeira = captions[0] or {}
        descricao = primeira.get("text") or "Descricao nao disponivel."
        confianca = _arredondar_confianca(primeira.get("confidence"))
    else:
        descricao = "Descricao nao disponivel."
        confianca = None

    etiquetas = []
    for tag in tags_gerais:
        nome = tag.get("name")
        if not nome:
            continue
        etiquetas.append(
            {
                "nome": nome,
                "confianca": _arredondar_confianca(tag.get("confidence")),
            }
        )

    # Fallback para quando a lista principal de tags vier vazia.
    if not etiquetas:
        for nome in tags_descricao:
            if not nome:
                continue
            etiquetas.append({"nome": nome, "confianca": None})

    objetos = []
    for obj in objetos_gerais:
        nome = obj.get("object") or obj.get("name")
        if not nome:
            continue
        objetos.append(
            {
                "nome": nome,
                "confianca": _arredondar_confianca(obj.get("confidence")),
            }
        )

    return {
        "descricao": descricao,
        "confianca": confianca,
        "etiquetas": etiquetas,
        "objetos": objetos,
    }


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.post("/api/analisar")
def analisar():
    try:
        imagem_bytes = _validar_e_ler_arquivo()
        endpoint, key = _obter_config_vision()
        resposta_vision = _chamar_vision(imagem_bytes, endpoint, key)
        resultado = _normalizar_resultado(resposta_vision)
        return jsonify(resultado)
    except VisionApiError as erro:
        return _json_erro(erro.mensagem, erro.status_code)
    except Exception:
        logger.exception("Falha inesperada durante a analise da imagem.")
        return _json_erro(
            "Ocorreu um erro inesperado durante a analise. Tente novamente.", 500
        )


@app.errorhandler(413)
def arquivo_grande(_erro):
    return _json_erro("A imagem excede 4 MB. Envie um arquivo menor.", 413)


if __name__ == "__main__":
    # Execucao local opcional para desenvolvimento.
    app.run(host="127.0.0.1", port=5000, debug=True)
