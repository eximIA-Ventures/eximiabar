import Foundation

/// The static shell of `painel.html`: document, stylesheet and behaviour, with no data in it.
///
/// **Why a raw string in a `.swift` file, and not a resource.** `.copy("Resources/painel.html")` was
/// the obvious answer and is the wrong one *for this repository*: EXB-3.3 already cost a release to a
/// resource bundle — the app crashed at launch when the bundle was missing, and `Scripts/package_app.sh`
/// exists because of it. A template compiled into the binary has no packaging failure mode at all.
/// The raw delimiter `#"""…"""#` is what makes CSS and JS survive intact: `{`, `}` and `\` need no
/// escaping, and interpolation only happens at the explicit hash-escaped marker.
///
/// **Exactly two injection points, and a test that counts them.** `PainelHTMLTests` counts the
/// interpolation markers in **this whole file, comments included** — so an example of the marker
/// written in prose here would fail the gate, which is why the text above spells it out in words
/// instead. That count is the whole security argument of the panel: the surface where
/// outside text meets markup is small enough to read in one sitting, and both of its halves go through
/// ``PainelEscape``.
public enum PainelTemplate {
    /// Wraps the generated body and the data block into the finished document.
    ///
    /// - Parameters:
    ///   - corpo: markup produced by ``PainelHTMLWriter`` — already escaped, already containing the SVG.
    ///   - dados: the JSON payload — already escaped by ``PainelEscape/json(_:)``.
    public static func pagina(corpo: String, dados: String) -> String {
        #"""
        <!DOCTYPE html>
        <html lang="pt-BR">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Uso do Claude Code — exímIABar</title>
        <style>
        :root {
          --fundo: #111827;
          --cartao: #1A2233;
          --borda: #2A3346;
          --grade: #232C3E;
          --texto: #E8EAF0;
          --suave: #9AA4B8;
          --destaque: #CC7C5E;
          --acima: #D16B4C;
          --abaixo: #4C9E66;
        }
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; }
        body {
          background: var(--fundo);
          color: var(--texto);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
          font-size: 15px;
          line-height: 1.5;
          -webkit-font-smoothing: antialiased;
        }
        .pagina { max-width: 1120px; margin: 0 auto; padding: 40px 28px 72px; }
        header h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.2px; }
        header .janela { color: var(--suave); margin: 0 0 24px; }
        .cobertura {
          background: var(--cartao);
          border: 1px solid var(--borda);
          border-left: 3px solid var(--destaque);
          border-radius: 10px;
          padding: 18px 20px;
          margin-bottom: 32px;
        }
        .cobertura h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 1px; color: var(--suave); margin: 0 0 12px; }
        .cobertura dl { display: flex; flex-wrap: wrap; gap: 28px; margin: 0; }
        .cobertura dt { font-size: 12px; color: var(--suave); margin: 0 0 2px; }
        .cobertura dd { margin: 0; font-size: 18px; font-variant-numeric: tabular-nums; }
        .cobertura .aviso { margin: 14px 0 0; color: var(--acima); font-size: 14px; }
        .cobertura .aviso.completa { color: var(--abaixo); }
        h2.secao { font-size: 13px; text-transform: uppercase; letter-spacing: 1px; color: var(--suave); margin: 34px 0 14px; }
        .cartoes { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 14px; }
        .cartao {
          background: var(--cartao);
          border: 1px solid var(--borda);
          border-radius: 10px;
          padding: 16px 18px;
        }
        .cartao .rotulo { font-size: 12px; color: var(--suave); }
        .cartao .numero { font-size: 25px; font-variant-numeric: tabular-nums; margin-top: 6px; letter-spacing: -0.4px; }
        .cartao .nota { font-size: 12px; color: var(--suave); margin-top: 4px; }
        .cartao.custo .numero { color: var(--destaque); }
        .ressalva-custo { color: var(--suave); font-size: 13px; margin: 0 0 12px; max-width: 62ch; }
        .grafico-bloco {
          background: var(--cartao);
          border: 1px solid var(--borda);
          border-radius: 10px;
          padding: 18px 20px 12px;
          margin-top: 18px;
        }
        .grafico-bloco h3 { margin: 0; font-size: 16px; }
        .grafico-bloco .sub { margin: 2px 0 10px; font-size: 12px; color: var(--suave); }
        .grafico { width: 100%; height: auto; display: block; overflow: visible; }
        .grafico .grade line { stroke: var(--grade); stroke-width: 1; }
        .grafico .base { stroke: var(--borda); stroke-width: 1; }
        .grafico text { fill: var(--suave); font-size: 11px; font-family: inherit; }
        .grafico text.rotulo { fill: var(--texto); font-size: 12px; }
        .grafico text.valor { fill: var(--suave); font-size: 12px; font-variant-numeric: tabular-nums; }
        .grafico text.vazio { fill: var(--suave); font-size: 13px; }
        .grafico .trilho { fill: var(--grade); }
        .grafico .serie { transition: opacity 120ms ease; }
        .grafico .serie.apagada { opacity: 0.12; }
        .legenda { display: flex; flex-wrap: wrap; gap: 8px; margin: 10px 0 4px; }
        .legenda button {
          display: inline-flex; align-items: center; gap: 7px;
          background: transparent; color: var(--texto);
          border: 1px solid var(--borda); border-radius: 999px;
          padding: 4px 12px 4px 8px; font: inherit; font-size: 12px; cursor: pointer;
        }
        .legenda button .amostra { width: 10px; height: 10px; border-radius: 3px; background: var(--cor); }
        .legenda button.apagada { opacity: 0.42; }
        .legenda button:focus-visible { outline: 2px solid var(--destaque); outline-offset: 2px; }
        #dica {
          position: fixed; z-index: 20; pointer-events: none;
          background: #0B111E; color: var(--texto);
          border: 1px solid var(--borda); border-radius: 8px;
          padding: 7px 11px; font-size: 12.5px; line-height: 1.45;
          box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
          opacity: 0; transform: translateY(-4px); transition: opacity 90ms ease;
          max-width: 340px;
        }
        #dica.visivel { opacity: 1; }
        footer { margin-top: 46px; border-top: 1px solid var(--borda); padding-top: 18px; color: var(--suave); font-size: 13px; }
        footer h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 1px; margin: 0 0 10px; color: var(--suave); }
        footer ul { margin: 0; padding-left: 18px; }
        footer li { margin-bottom: 6px; max-width: 78ch; }
        @media (max-width: 640px) {
          .pagina { padding: 24px 16px 48px; }
          .cobertura dl { gap: 18px; }
        }
        @media print {
          body { background: #fff; color: #111; }
          .cartao, .cobertura, .grafico-bloco { background: #fff; border-color: #ccc; }
          .legenda { display: none; }
        }
        </style>
        </head>
        <body>
        <div class="pagina">
        \#(corpo)
        </div>
        <div id="dica" role="status" aria-live="polite"></div>
        <script id="dados" type="application/json">\#(dados)</script>
        <script>
        /* Progressive enhancement only. Every chart above is already drawn in the markup, and every
           hoverable element carries a <title>, so with scripting disabled the panel keeps working —
           it just loses the floating tooltip and the ability to dim a series. */
        (function () {
          "use strict";

          var dica = document.getElementById("dica");
          var alvoAtual = null;

          function textoDoAlvo(no) {
            while (no && no !== document.body) {
              if (no.getAttribute && no.getAttribute("data-dica")) { return no; }
              no = no.parentNode;
            }
            return null;
          }

          function posicionar(evento) {
            var margem = 14;
            var caixa = dica.getBoundingClientRect();
            var x = evento.clientX + margem;
            var y = evento.clientY + margem;
            if (x + caixa.width > window.innerWidth - 8) { x = evento.clientX - caixa.width - margem; }
            if (y + caixa.height > window.innerHeight - 8) { y = evento.clientY - caixa.height - margem; }
            dica.style.left = Math.max(8, x) + "px";
            dica.style.top = Math.max(8, y) + "px";
          }

          document.addEventListener("mousemove", function (evento) {
            var no = textoDoAlvo(evento.target);
            if (!no) {
              if (alvoAtual) { alvoAtual = null; dica.classList.remove("visivel"); }
              return;
            }
            if (no !== alvoAtual) {
              alvoAtual = no;
              dica.textContent = no.getAttribute("data-dica");
              dica.classList.add("visivel");
            }
            posicionar(evento);
          });

          document.addEventListener("scroll", function () {
            alvoAtual = null;
            dica.classList.remove("visivel");
          }, true);

          /* Legend: dim a series instead of removing it. Removing one from a stacked chart would
             require re-laying out the stack in the browser, which is exactly the runtime rendering
             this panel avoids — and a hole in the middle of a stack reads as missing data. */
          var botoes = document.querySelectorAll(".legenda button[data-grafico]");
          Array.prototype.forEach.call(botoes, function (botao) {
            botao.addEventListener("click", function () {
              var grafico = document.querySelector('[data-grafico="' + botao.getAttribute("data-grafico") + '"]');
              if (!grafico) { return; }
              var serie = grafico.querySelector('.serie[data-serie="' + botao.getAttribute("data-serie") + '"]');
              if (!serie) { return; }
              var apagando = !botao.classList.contains("apagada");
              botao.classList.toggle("apagada", apagando);
              serie.classList.toggle("apagada", apagando);
              botao.setAttribute("aria-pressed", apagando ? "false" : "true");
            });
            botao.setAttribute("aria-pressed", "true");
          });
        }());
        </script>
        </body>
        </html>
        """#
    }
}
