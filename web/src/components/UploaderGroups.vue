<script setup>
import { computed } from 'vue'
import { store } from '../store'
import PreviewMedia from './PreviewMedia.vue'

// 按上传者分组，组按最新上传时间排序
const groups = computed(() => {
  const map = new Map()
  for (const f of store.files) {
    if (!map.has(f.uploader)) map.set(f.uploader, [])
    map.get(f.uploader).push(f)
  }
  return [...map.entries()]
    .map(([name, files]) => ({
      name,
      count: files.length,
      cover: [...files].sort((a, b) => b.uploadedAt - a.uploadedAt)[0],
    }))
    .sort((a, b) => b.cover.uploadedAt - a.cover.uploadedAt)
})

const gridClass = computed(
  () =>
    ({
      2: 'grid-cols-2',
      3: 'grid-cols-3',
      4: 'grid-cols-4',
    })[store.grid],
)

function open(name) {
  store.activeUploader = name
}
</script>

<template>
  <div v-if="groups.length === 0" class="py-24 text-center text-gray-400">
    还没有内容
  </div>
  <div v-else class="px-4 py-3">
    <div class="grid gap-3" :class="gridClass">
      <figure
        v-for="g in groups"
        :key="g.name"
        class="cursor-pointer"
        @click="open(g.name)"
      >
        <div class="relative aspect-square bg-gray-100 dark:bg-gray-700 rounded-lg overflow-hidden">
          <PreviewMedia :file="g.cover" :show-badge="false" />
          <span class="absolute right-1 bottom-1 px-1 rounded bg-black/45 text-white text-[10px] leading-4">{{ g.count }}</span>
        </div>
        <figcaption class="px-1 py-1 text-xs truncate text-center">{{ g.name }}</figcaption>
      </figure>
    </div>
  </div>
</template>
