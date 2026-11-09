<script setup>
import { onMounted, onUnmounted, watch } from 'vue'
import { api } from './api'
import { store } from './store'
import { connectionMessage, validateMeta } from './model'
import HeaderBar from './components/HeaderBar.vue'
import Toolbar from './components/Toolbar.vue'
import Gallery from './components/Gallery.vue'
import UploaderGroups from './components/UploaderGroups.vue'
import Lightbox from './components/Lightbox.vue'

let timer = null
let controller = null
let stopped = false
let pollFailures = 0

function scheduleRefresh(delay) {
  clearTimeout(timer)
  if (!stopped) timer = setTimeout(refresh, delay)
}

async function refresh() {
  if (stopped) return
  if (controller) return
  if (document.hidden) {
    scheduleRefresh(15000)
    return
  }
  controller = new AbortController()
  try {
    store.files = await api.files(controller.signal)
    pollFailures = 0
    store.connectionWarning = ''
  } catch (e) {
    if (e.name !== 'AbortError') {
      pollFailures += 1
      store.connectionWarning = connectionMessage(e, { polling: true })
      console.debug('[LinkNest Web] 文件列表刷新失败', {
        code: e.code,
        status: e.status,
        failures: pollFailures,
      })
    }
  } finally {
    controller = null
    const retryDelay = Math.min(30000, 4000 * 2 ** pollFailures)
    scheduleRefresh(retryDelay)
  }
}

function retryConnection() {
  clearTimeout(timer)
  pollFailures = 0
  refresh()
}

function onVisibilityChange() {
  clearTimeout(timer)
  scheduleRefresh(document.hidden ? 15000 : 0)
}

// 深色模式：跟随 store.dark，切换 <html> 的 dark 类（Tailwind v4 手动深色）
watch(
  () => store.dark,
  (v) => document.documentElement.classList.toggle('dark', v),
  { immediate: true },
)

// 拦截浏览器后退：弹「要退出吗」，确认才真正离开
function onPopstate() {
  if (window.confirm('要退出空间吗？')) {
    window.removeEventListener('popstate', onPopstate)
    history.back()
  } else {
    history.pushState(null, '', location.href)
  }
}

onMounted(async () => {
  history.pushState(null, '', location.href)
  window.addEventListener('popstate', onPopstate)
  document.addEventListener('visibilitychange', onVisibilityChange)

  let authContext = 'session'
  try {
    const session = await api.establishSession()
    authContext = session.usedToken ? 'token' : 'session'
    store.meta = validateMeta(await api.meta())
  } catch (e) {
    store.error = connectionMessage(e, { authContext: e.authContext || authContext })
    console.debug('[LinkNest Web] 加入空间失败', { code: e.code, status: e.status })
    return
  }
  await refresh()
})

onUnmounted(() => {
  stopped = true
  clearTimeout(timer)
  controller?.abort()
  document.removeEventListener('visibilitychange', onVisibilityChange)
  window.removeEventListener('popstate', onPopstate)
})
</script>

<template>
  <div class="min-h-screen bg-gray-50 text-gray-900 dark:bg-gray-900 dark:text-gray-100">
    <HeaderBar />
    <Toolbar v-if="!store.error" />

    <p v-if="store.error" class="mx-auto max-w-5xl px-4 py-3 text-sm text-red-600">
      无法加入空间：{{ store.error }}
    </p>

    <div
      v-else-if="store.connectionWarning"
      class="mx-auto flex max-w-5xl items-center gap-3 px-4 py-3 text-sm text-amber-700 dark:text-amber-300"
    >
      <span class="flex-1">{{ store.connectionWarning }}</span>
      <button class="shrink-0 rounded border border-current px-2 py-1" @click="retryConnection">
        立即重试
      </button>
    </div>

    <!-- 默认模式：所有图片网格 -->
    <main v-if="!store.error && store.mode === 'default'" class="max-w-5xl mx-auto px-4 pb-16">
      <Gallery />
    </main>

    <!-- 上传者模式：文件夹宫格 -->
    <main v-else-if="!store.error && store.activeUploader === null" class="max-w-5xl mx-auto px-4 pb-16">
      <UploaderGroups />
    </main>

    <!-- 上传者模式：某上传者的图片 + 返回 -->
    <template v-else-if="!store.error">
      <div class="flex items-center gap-2 px-4 py-2 text-sm border-b border-gray-200 dark:border-gray-800">
        <button class="text-gray-500 dark:text-gray-400" @click="store.activeUploader = null">‹ 返回</button>
        <span class="font-medium truncate">{{ store.activeUploader }}</span>
      </div>
      <main class="max-w-5xl mx-auto px-4 pb-16">
        <Gallery />
      </main>
    </template>

    <Lightbox v-if="store.lightboxFile" />
  </div>
</template>
