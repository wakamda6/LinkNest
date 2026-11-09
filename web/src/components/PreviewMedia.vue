<script setup>
import { computed, ref, watch } from 'vue'
import { fileBadge, mediaUrl, previewState } from '../model'

const props = defineProps({
  file: { type: Object, required: true },
  variant: { type: String, default: 'thumbnail' },
  imageClass: { type: String, default: 'w-full h-full object-cover' },
  showBadge: { type: Boolean, default: true },
})

const loaded = ref(false)
const loadFailed = ref(false)
const retry = ref(0)
const state = computed(() => previewState(props.file, loadFailed.value))
const source = computed(() => mediaUrl(props.file, props.variant, retry.value))
const badge = computed(() => fileBadge(props.file))

watch(
  [() => props.file.id, () => props.file.previewStatus, () => props.variant],
  () => {
    loaded.value = false
    loadFailed.value = false
    retry.value = 0
  },
)

function onLoad() {
  loaded.value = true
  loadFailed.value = false
}

function onError() {
  loaded.value = false
  loadFailed.value = true
  console.debug('[LinkNest Web] 预览加载失败', {
    id: props.file.id,
    variant: props.variant,
  })
}

function retryLoad() {
  loaded.value = false
  loadFailed.value = false
  retry.value += 1
}
</script>

<template>
  <div class="relative w-full h-full flex items-center justify-center">
    <img
      v-if="state.canLoad"
      :src="source"
      :class="[imageClass, { 'opacity-0': !loaded }]"
      :loading="variant === 'thumbnail' ? 'lazy' : undefined"
      draggable="false"
      @load="onLoad"
      @error="onError"
    />
    <div
      v-if="!loaded"
      class="absolute inset-0 flex flex-col items-center justify-center gap-2 px-3 text-center text-xs text-gray-400"
    >
      <span>{{ state.message }}</span>
      <button
        v-if="state.retryable"
        type="button"
        class="pointer-events-auto rounded border border-gray-400 px-2 py-1 text-gray-300"
        @pointerdown.stop
        @pointerup.stop
        @click.stop="retryLoad"
      >
        重试
      </button>
    </div>
    <span
      v-if="showBadge && badge"
      class="absolute right-1 bottom-1 px-1.5 rounded bg-black/45 text-white text-[10px] leading-4"
    >{{ badge }}</span>
  </div>
</template>
