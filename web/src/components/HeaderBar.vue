<script setup>
import { ref } from 'vue'
import { api } from '../api'
import { store } from '../store'

const fileInput = ref(null)
const msg = ref('')
const mediaExtensions = new Set([
  'jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'webp', 'bmp', 'tif', 'tiff',
  'mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm', 'avi', 'mpeg', 'mpg',
])

function isAcceptedMedia(file) {
  const dot = file.name.lastIndexOf('.')
  if (dot < 0 || dot === file.name.length - 1) return false
  return mediaExtensions.has(file.name.slice(dot + 1).toLowerCase())
}

function pick() {
  fileInput.value.click()
}

async function onFiles(e) {
  const selected = Array.from(e.target.files)
  if (selected.length === 0) return
  const files = selected.filter(isAcceptedMedia)
  const unsupported = selected.length - files.length
  if (files.length === 0) {
    msg.value = `已跳过 ${unsupported} 个非图片或视频文件`
    fileInput.value.value = ''
    return
  }
  store.uploading = true
  store.uploadProgress = 0
  msg.value = ''
  const totalBytes = files.reduce((sum, file) => sum + file.size, 0)
  let completedBytes = 0
  let uploaded = 0
  let skipped = 0
  const failures = []
  try {
    for (const file of files) {
      const fd = new FormData()
      fd.append('uploader', store.meta.visitorName || '未知')
      fd.append('file', file)
      try {
        const created = await api.upload(fd, (percent) => {
          const currentBytes = file.size * (percent / 100)
          store.uploadProgress = totalBytes > 0
            ? Math.round(((completedBytes + currentBytes) / totalBytes) * 100)
            : percent
        })
        completedBytes += file.size
        store.uploadProgress = totalBytes > 0
          ? Math.round((completedBytes / totalBytes) * 100)
          : 100
        if (created.length === 0) {
          skipped += 1
          continue
        }
        uploaded += created.length
        const known = new Set(store.files.map((item) => item.id))
        store.files = [...created.filter((item) => !known.has(item.id)), ...store.files]
      } catch (err) {
        completedBytes += file.size
        failures.push(`${file.name}：${err.message}`)
      }
    }
    const parts = []
    if (uploaded > 0) parts.push(`上传 ${uploaded} 个`)
    if (skipped > 0) parts.push(`跳过 ${skipped} 个重复`)
    if (unsupported > 0) parts.push(`跳过 ${unsupported} 个非图片或视频文件`)
    if (failures.length > 0) parts.push(`${failures.length} 个失败（${failures.join('；')}）`)
    msg.value = parts.join('，') || '没有文件被上传'
  } finally {
    store.uploading = false
    store.uploadProgress = 0
    fileInput.value.value = ''
  }
}
</script>

<template>
  <header class="sticky top-0 z-10 bg-white/80 dark:bg-gray-900/80 backdrop-blur border-b border-gray-200 dark:border-gray-800">
    <div class="max-w-5xl mx-auto px-4 py-3 flex items-center justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-lg font-bold leading-tight truncate">{{ store.meta.spaceName || 'LinkNest' }}</h1>
        <p class="text-sm text-gray-500 dark:text-gray-400 truncate">我是 {{ store.meta.visitorName || '…' }}</p>
      </div>
      <input
        ref="fileInput"
        type="file"
        multiple
        accept="image/*,video/*,.heic,.heif,.m4v,.3gp,.mkv,.webm,.avi,.mpeg,.mpg,.tif,.tiff"
        class="hidden"
        @change="onFiles"
      />
      <button
        class="shrink-0 px-4 py-2 rounded-lg bg-teal-600 text-white font-medium disabled:opacity-50"
        :disabled="store.uploading || !!store.error"
        @click="pick"
      >
        {{ store.uploading ? '上传中…' : '上传' }}
      </button>
    </div>
    <!-- 上传进度条 -->
    <div v-if="store.uploading" class="h-1 bg-gray-200 dark:bg-gray-700 overflow-hidden">
      <div
        class="h-full bg-teal-600 transition-[width] duration-200"
        :class="store.uploadProgress === 0 ? 'w-full animate-pulse' : ''"
        :style="store.uploadProgress > 0 ? { width: store.uploadProgress + '%' } : {}"
      />
    </div>
    <p v-if="msg" class="px-4 pb-2 text-sm text-red-500">{{ msg }}</p>
    <p class="px-4 pb-2 text-xs text-gray-500 dark:text-gray-400">
      Web 备用入口不能创建 Live Photo；需要上传 Live Photo 时请使用 iOS App。
    </p>
  </header>
</template>
