# EXB-3.4 — npx installer (npm package)

**Status:** Done (publish pendente de `npm login` do Hugo)
**Executor:** J.A.R.V.I.S. direto (Tier 2 — story leve, Maestri offline)
**Depends on:** EXB-3.3 (release v1.2.0 pública)

## Story

Como usuário do ecossistema node, quero instalar o exímIABar com `npx eximiabar`, para ter o mesmo fluxo de instalação do Claude Code (`npm install -g`).

## Decisão de design

O app nativo não vira pacote JS — o pacote npm é um **instalador**: baixa o asset `.zip` da release mais recente do GitHub, extrai com `ditto` (preserva assinatura), instala em `/Applications` (fallback `~/Applications` sem permissão), remove quarantine e abre. Padrão estabelecido (Claude Code, playwright, esbuild distribuem binários via npm).

## Acceptance Criteria

1. ✅ `npm/package.json` — name `eximiabar`, bin `eximiabar`, `os: [darwin]`, `engines node >=18` (fetch global), versão alinhada à release (1.2.0)
2. ✅ `npm/bin/install.js` — node puro sem dependências; GitHub Releases API → latest; encerra app rodando antes de substituir; `ditto` para extração e cópia; `xattr -dr com.apple.quarantine`; `open` ao final; mensagens PT/EN
3. ✅ Teste real: `node npm/bin/install.js` baixou v1.2.0 (1.8 MB), instalou em `/Applications`, app relançado vivo (pgrep ✓) — 2026-06-12
4. ✅ README principal com seção npx
5. ⏳ `npm publish` — requer `npm login` do Hugo (E401 na máquina; nome `eximiabar` livre no registry, verificado 2026-06-12)

## Dev Notes

- O instalador sempre baixa a **latest** release — o pacote npm não precisa de bump a cada release do app; bump só se o script mudar.
- Publicação: `cd npm && npm publish` (após login). Considerar `npm publish --access public` se escopo futuro.
