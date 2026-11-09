import { cp, mkdir, rm } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = resolve(webRoot, 'dist')
const destination = resolve(webRoot, '..', 'host_app', 'assets', 'web')

await rm(destination, { recursive: true, force: true })
await mkdir(destination, { recursive: true })
await cp(source, destination, { recursive: true })

console.log('[LinkNest] Web 资源已同步到 Host 内置资源目录')
