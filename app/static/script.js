const MAX_SIZE = 4 * 1024 * 1024;
const MIME_PERMITIDOS = ["image/jpeg", "image/jpg", "image/png", "image/bmp", "image/gif"];
const EXT_PERMITIDAS = [".jpg", ".jpeg", ".png", ".bmp", ".gif"];

const form = document.getElementById("form-analise");
const inputImagem = document.getElementById("imagem");
const botao = document.getElementById("botao-analisar");
const erroBox = document.getElementById("erro");
const loadingBox = document.getElementById("loading");
const resultadoBox = document.getElementById("resultado");
const previewWrapper = document.getElementById("preview-wrapper");
const preview = document.getElementById("preview");

const descricaoTexto = document.getElementById("descricao-texto");
const descricaoConfianca = document.getElementById("descricao-confianca");
const listaEtiquetas = document.getElementById("lista-etiquetas");
const listaObjetos = document.getElementById("lista-objetos");

function mostrarErro(mensagem) {
  erroBox.textContent = mensagem;
  erroBox.classList.remove("hidden");
}

function limparErro() {
  erroBox.textContent = "";
  erroBox.classList.add("hidden");
}

function mostrarLoading(ativo) {
  if (ativo) {
    loadingBox.classList.remove("hidden");
    botao.disabled = true;
    return;
  }
  loadingBox.classList.add("hidden");
  botao.disabled = false;
}

function limparResultado() {
  resultadoBox.classList.add("hidden");
  descricaoTexto.textContent = "";
  descricaoConfianca.textContent = "";
  listaEtiquetas.innerHTML = "";
  listaObjetos.innerHTML = "";
}

function formatarPercentual(confianca) {
  if (typeof confianca !== "number" || Number.isNaN(confianca)) {
    return "N/A";
  }
  return `${(confianca * 100).toFixed(1)}%`;
}

function criarItem(nome, confianca) {
  const valorNormalizado = typeof confianca === "number" ? Math.max(0, Math.min(1, confianca)) : null;
  const percentualTexto = formatarPercentual(valorNormalizado);
  const largura = valorNormalizado === null ? 0 : Math.round(valorNormalizado * 100);

  const li = document.createElement("li");
  li.className = "item";

  const head = document.createElement("div");
  head.className = "item-head";

  const strong = document.createElement("strong");
  strong.textContent = nome;

  const span = document.createElement("span");
  span.textContent = percentualTexto;

  const barra = document.createElement("div");
  barra.className = "barra";

  const barraFill = document.createElement("i");
  barraFill.style.width = `${largura}%`;

  head.appendChild(strong);
  head.appendChild(span);
  barra.appendChild(barraFill);
  li.appendChild(head);
  li.appendChild(barra);

  return li;
}

function preencherLista(elementoLista, itens, vazioMensagem) {
  elementoLista.innerHTML = "";
  if (!Array.isArray(itens) || itens.length === 0) {
    const vazio = document.createElement("li");
    vazio.className = "vazio";
    vazio.textContent = vazioMensagem;
    elementoLista.appendChild(vazio);
    return;
  }
  itens.forEach((item) => {
    elementoLista.appendChild(criarItem(item.nome || "sem nome", item.confianca));
  });
}

function validarArquivo(arquivo) {
  if (!arquivo) {
    return "Selecione uma imagem antes de analisar.";
  }

  const nome = (arquivo.name || "").toLowerCase();
  const possuiExtensaoPermitida = EXT_PERMITIDAS.some((ext) => nome.endsWith(ext));
  if (!possuiExtensaoPermitida) {
    return "Formato nao suportado. Envie JPG, PNG, BMP ou GIF.";
  }

  const tipo = (arquivo.type || "").toLowerCase();
  if (tipo && !MIME_PERMITIDOS.includes(tipo)) {
    return "Tipo de arquivo invalido. Selecione uma imagem valida.";
  }

  if (arquivo.size === 0) {
    return "A imagem enviada esta vazia.";
  }

  if (arquivo.size > MAX_SIZE) {
    return "A imagem excede 4 MB. Escolha um arquivo menor.";
  }

  return null;
}

inputImagem.addEventListener("change", () => {
  limparErro();
  limparResultado();

  const arquivo = inputImagem.files && inputImagem.files[0];
  if (!arquivo) {
    previewWrapper.classList.add("hidden");
    preview.removeAttribute("src");
    return;
  }

  const erro = validarArquivo(arquivo);
  if (erro) {
    mostrarErro(erro);
    previewWrapper.classList.add("hidden");
    preview.removeAttribute("src");
    return;
  }

  const leitor = new FileReader();
  leitor.onload = (evento) => {
    preview.src = evento.target.result;
    previewWrapper.classList.remove("hidden");
  };
  leitor.readAsDataURL(arquivo);
});

form.addEventListener("submit", async (evento) => {
  evento.preventDefault();
  limparErro();
  limparResultado();

  const arquivo = inputImagem.files && inputImagem.files[0];
  const erroValidacao = validarArquivo(arquivo);
  if (erroValidacao) {
    mostrarErro(erroValidacao);
    return;
  }

  const formData = new FormData();
  formData.append("imagem", arquivo);
  mostrarLoading(true);

  try {
    const resposta = await fetch("/api/analisar", {
      method: "POST",
      body: formData,
    });
    const dados = await resposta.json();

    if (!resposta.ok) {
      throw new Error(dados.erro || "Falha na analise da imagem.");
    }

    descricaoTexto.textContent = dados.descricao || "Descricao nao disponivel.";
    descricaoConfianca.textContent = `Confianca: ${formatarPercentual(dados.confianca)}`;

    preencherLista(listaEtiquetas, dados.etiquetas, "Nenhuma etiqueta identificada.");
    preencherLista(listaObjetos, dados.objetos, "Nenhum objeto identificado.");
    resultadoBox.classList.remove("hidden");
  } catch (erro) {
    if (erro instanceof TypeError) {
      mostrarErro("Falha de rede ao enviar a imagem. Verifique sua conexao e tente novamente.");
    } else {
      mostrarErro(erro.message || "Nao foi possivel concluir a analise.");
    }
  } finally {
    mostrarLoading(false);
  }
});
