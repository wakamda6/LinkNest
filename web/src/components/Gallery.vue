<script setup>
import { computed } from 'vue'
import { store, visibleFiles } from '../store'
import PreviewMedia from './PreviewMedia.vue'

// 上传者模式下只看该上传者，默认模式看全部
const sorted = computed(() => visibleFiles())

const gridClass = computed(
  () =>
    ({
      2: 'grid-cols-2',
      3: 'grid-cols-3',
      4: 'grid-cols-4',
    })[store.grid],
)

function open(f) {
  store.lightboxFile = f
}

</script>

<template>
  <div v-if="sorted.length === 0" class="py-24 text-center text-gray-400">
    有照片/视频要上传吗？点右上角「上传」
  </div>
  <div v-else class="grid gap-3" :class="gridClass">
    <figure
      v-for="f in sorted"
      :key="f.id"
      class="bg-white dark:bg-gray-800 rounded-lg overflow-hidden shadow-sm cursor-pointer"
      @click="open(f)"
    >
      <div class="relative aspect-square bg-gray-100 dark:bg-gray-700">
        <PreviewMedia :file="f" />
      </div>
    </figure>
  </div>
</template>
