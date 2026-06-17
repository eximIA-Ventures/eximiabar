#!/usr/bin/env node
// exímIABar npx installer — downloads the latest GitHub release and installs
// the .app into /Applications. macOS only.
'use strict'

const { execFileSync, execSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const REPO = 'eximIA-Ventures/eximiabar'
const APP_NAME = 'ExímIABar.app'
const PROCESS_NAME = 'ClaudeBar'
const UA = { 'User-Agent': 'eximiabar-npx-installer' }

async function fetchJSON(url) {
  const res = await fetch(url, { headers: { ...UA, Accept: 'application/vnd.github+json' } })
  if (!res.ok) throw new Error(`GitHub API ${res.status} em ${url}`)
  return res.json()
}

async function main() {
  if (process.platform !== 'darwin') {
    console.error('exímIABar é um app de menu bar do macOS — only macOS is supported.')
    process.exit(1)
  }

  console.log('exímIABar — buscando a release mais recente / fetching latest release...')
  const rel = await fetchJSON(`https://api.github.com/repos/${REPO}/releases/latest`)
  const asset = (rel.assets || []).find((a) => a.name.endsWith('.zip'))
  if (!asset) throw new Error(`release ${rel.tag_name} sem asset .zip — https://github.com/${REPO}/releases`)

  console.log(`Baixando ${rel.tag_name} (${(asset.size / 1048576).toFixed(1)} MB)...`)
  const res = await fetch(asset.browser_download_url, { headers: UA })
  if (!res.ok) throw new Error(`download falhou: HTTP ${res.status}`)
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'eximiabar-'))
  const zipPath = path.join(tmp, asset.name)
  fs.writeFileSync(zipPath, Buffer.from(await res.arrayBuffer()))

  // ditto preserves the code signature and resource forks while unzipping.
  execFileSync('/usr/bin/ditto', ['-xk', zipPath, tmp])
  const appSrc = path.join(tmp, APP_NAME)
  if (!fs.existsSync(appSrc)) throw new Error(`bundle ${APP_NAME} não encontrado no zip`)

  let destDir = '/Applications'
  try {
    fs.accessSync(destDir, fs.constants.W_OK)
  } catch {
    destDir = path.join(os.homedir(), 'Applications')
    fs.mkdirSync(destDir, { recursive: true })
  }
  const dest = path.join(destDir, APP_NAME)

  try { execSync(`pkill -x ${PROCESS_NAME}`, { stdio: 'ignore' }) } catch { /* not running */ }
  fs.rmSync(dest, { recursive: true, force: true })
  execFileSync('/usr/bin/ditto', [appSrc, dest])
  try { execFileSync('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', dest]) } catch { /* no quarantine */ }
  fs.rmSync(tmp, { recursive: true, force: true })

  execFileSync('/usr/bin/open', [dest])
  console.log(`Instalado em ${dest} — exímIABar está na sua menu bar. ✓`)
  console.log('Para atualizar depois: npx eximiabar (ou o botão Check for Updates no app).')
}

main().catch((err) => {
  console.error(`Falha na instalação: ${err.message}`)
  process.exit(1)
})
