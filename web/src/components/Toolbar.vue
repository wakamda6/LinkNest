<script setup>
import { store } from '../store'

const modeOptions = [
  { value: 'default', label: '默认' },
  { value: 'uploader', label: '上传者' },
]
const gridOptions = [
  { n: 2, label: '大' },
  { n: 3, label: '中' },
  { n: 4, label: '小' },
]

function onModeChange(e) {
  store.mode = e.target.value
  if (store.mode === 'uploader') store.activeUploader = null
}
</script>

<template>
  <div class="flex items-center gap-2 px-4 py-2 border-b border-gray-200 dark:border-gray-800">
    <!-- 一级：默认 / 上传者 -->
    <select
      :value="store.mode"
      @change="onModeChange"
      class="text-sm bg-transparent border border-gray-300 dark:border-gray-600 rounded-md px-2 py-1 dark:bg-gray-800 dark:text-gray-200"
    >
      <option v-for="m in modeOptions" :key="m.value" :value="m.value">{{ m.label }}</option>
    </select>

    <!-- 二级：排序 -->
    <select
      v-model="store.sort"
      class="text-sm bg-transparent border border-gray-300 dark:border-gray-600 rounded-md px-2 py-1 dark:bg-gray-800 dark:text-gray-200"
    >
      <option value="newest">最新优先</option>
      <option value="oldest">最旧优先</option>
    </select>

    <div class="flex-1" />

    <!-- 二级：宫格大小 -->
    <div class="flex items-center gap-1">
      <button
        v-for="opt in gridOptions"
        :key="opt.n"
        class="text-sm px-2.5 py-1 rounded-md border transition-colors"
        :class="store.grid === opt.n
          ? 'bg-teal-600 text-white border-teal-600'
          : 'border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300'"
        @click="store.grid = opt.n"
      >{{ opt.label }}</button>
    </div>

    <!-- 二级：深色切换 -->
    <button
      class="text-sm px-2.5 py-1 rounded-md border border-gray-300 dark:border-gray-600 text-gray-600 dark:text-gray-300"
      @click="store.dark = !store.dark"
    >{{ store.dark ? '浅色' : '深色' }}</button>
  </div>
</template>
