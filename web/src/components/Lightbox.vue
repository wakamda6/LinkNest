<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { Zoom } from 'swiper/modules'
import { Swiper, SwiperSlide } from 'swiper/vue'
import 'swiper/css'
import 'swiper/css/zoom'

import { downloadResources } from '../model'
import { store, visibleFiles } from '../store'
import PreviewMedia from './PreviewMedia.vue'

const modules = [Zoom]
const currentId = ref(store.lightboxFile?.id || null)
const swiperInstance = ref(null)
const activeTouchPointers = new Set()
let removeGestureListeners = null
let latestZoomScale = 1
let pointerOutLogged = false

const files = computed(() => visibleFiles())
const currentIndex = computed(() =>
  files.value.findIndex((file) => file.id === currentId.value),
)
const initialIndex = Math.max(0, currentIndex.value)
const currentFile = computed(() =>
  currentIndex.value >= 0 ? files.value[currentIndex.value] : null,
)
const downloads = computed(() =>
  currentFile.value ? downloadResources(currentFile.value) : [],
)

onMounted(() => {
  if (currentIndex.value < 0) close()
  console.debug('[LinkNest Web] 大图已打开', {
    id: currentId.value,
  })
})

onUnmounted(() => {
  removeGestureListeners?.()
  activeTouchPointers.clear()
})

watch(files, async (nextFiles) => {
  const index = nextFiles.findIndex((file) => file.id === currentId.value)
  if (index < 0) {
    close()
    return
  }

  store.lightboxFile = nextFiles[index]
  await nextTick()
  const swiper = swiperInstance.value
  if (swiper && !swiper.destroyed && swiper.activeIndex !== index) {
    resetZoom(swiper)
    swiper.slideTo(index, 0)
  }
})

function onSwiper(swiper) {
  swiperInstance.value = swiper
  bindGestureTracking(swiper)
  syncCurrentFile(swiper.activeIndex)
}

function onSlideChange(swiper) {
  resetZoom(swiper)
  syncCurrentFile(swiper.activeIndex)
}

function onZoomChange(swiper, scale) {
  latestZoomScale = scale
  if (activeTouchPointers.size < 2) {
    syncSlideLock(swiper, scale, 'zoom-change')
  }
}

function bindGestureTracking(swiper) {
  removeGestureListeners?.()
  const wrapper = swiper.wrapperEl

  function onPointerDown(event) {
    if (event.pointerType === 'mouse') return
    activeTouchPointers.add(event.pointerId)
    if (activeTouchPointers.size === 2) {
      pointerOutLogged = false
      console.debug('[LinkNest Web] 大图双指缩放开始', {
        scale: latestZoomScale,
      })
    }
  }

  function onPointerFinish(event) {
    if (event.pointerType === 'mouse') return
    const wasPinching = activeTouchPointers.size >= 2
    activeTouchPointers.delete(event.pointerId)
    if (!wasPinching || activeTouchPointers.size >= 2) return

    requestAnimationFrame(() => {
      if (swiper.destroyed) return
      latestZoomScale = swiper.zoom.scale
      syncSlideLock(swiper, latestZoomScale, event.type)
      console.debug('[LinkNest Web] 大图双指缩放结束', {
        event: event.type,
        scale: latestZoomScale,
      })
    })
  }

  function onPointerOut(event) {
    if (activeTouchPointers.size < 2 || pointerOutLogged) return
    pointerOutLogged = true
    console.debug('[LinkNest Web] 缩放手势离开大图区域', {
      inside: event.relatedTarget
        ? wrapper.contains(event.relatedTarget)
        : false,
      scale: latestZoomScale,
    })
  }

  wrapper.addEventListener('pointerdown', onPointerDown, true)
  wrapper.addEventListener('pointerout', onPointerOut, true)
  window.addEventListener('pointerup', onPointerFinish, true)
  window.addEventListener('pointercancel', onPointerFinish, true)
  removeGestureListeners = () => {
    wrapper.removeEventListener('pointerdown', onPointerDown, true)
    wrapper.removeEventListener('pointerout', onPointerOut, true)
    window.removeEventListener('pointerup', onPointerFinish, true)
    window.removeEventListener('pointercancel', onPointerFinish, true)
    removeGestureListeners = null
  }
}

function syncSlideLock(swiper, scale, reason) {
  const canChangeSlide = scale <= 1.01
  const changed =
    swiper.allowSlideNext !== canChangeSlide ||
    swiper.allowSlidePrev !== canChangeSlide
  swiper.allowSlideNext = canChangeSlide
  swiper.allowSlidePrev = canChangeSlide
  if (changed) {
    console.debug('[LinkNest Web] 大图翻页锁定状态变化', {
      locked: !canChangeSlide,
      reason,
      scale,
    })
  }
}

function syncCurrentFile(index) {
  const target = files.value[index]
  if (!target) {
    close()
    return
  }
  currentId.value = target.id
  store.lightboxFile = target
}

function resetZoom(swiper) {
  if (swiper?.zoom?.scale > 1) swiper.zoom.out()
  if (swiper) {
    latestZoomScale = 1
    swiper.allowSlideNext = true
    swiper.allowSlidePrev = true
  }
}

function close() {
  resetZoom(swiperInstance.value)
  console.debug('[LinkNest Web] 大图已关闭', {
    id: currentId.value,
  })
  store.lightboxFile = null
}
</script>

<template>
  <div class="fixed inset-0 z-50 bg-black/90 select-none">
    <Swiper
      class="linknest-lightbox-swiper h-full w-full"
      :modules="modules"
      :initial-slide="initialIndex"
      :slides-per-view="1"
      :threshold="12"
      :touch-angle="40"
      :long-swipes-ms="300"
      :long-swipes-ratio="0.18"
      :resistance-ratio="0.4"
      :zoom="{ minRatio: 1, maxRatio: 4, toggle: true }"
      :watch-overflow="true"
      @swiper="onSwiper"
      @slide-change="onSlideChange"
      @zoom-change="onZoomChange"
    >
      <SwiperSlide
        v-for="file in files"
        :key="file.id"
        class="h-full"
      >
        <div class="swiper-zoom-container h-full w-full">
          <PreviewMedia
            :file="file"
            variant="preview"
            class="pointer-events-none"
            image-class="max-w-full max-h-full object-contain"
          />
        </div>
      </SwiperSlide>
    </Swiper>

    <button
      type="button"
      class="absolute left-4 z-10 rounded bg-black/60 px-3 py-2 text-sm text-white"
      style="top: max(1rem, env(safe-area-inset-top))"
      aria-label="关闭大图"
      @pointerdown.stop
      @pointerup.stop
      @click.stop="close"
    >
      关闭
    </button>

    <div
      class="absolute right-0 z-10 flex items-center gap-2 p-4"
      style="top: max(1rem, env(safe-area-inset-top))"
      @pointerdown.stop
      @pointerup.stop
    >
      <a
        v-for="item in downloads"
        :key="item.url"
        :href="item.url"
        class="inline-block rounded bg-teal-600 px-3 py-2 text-sm text-white"
        :download="item.name"
      >
        {{ item.label }}
      </a>
    </div>
  </div>
</template>

<style scoped>
.linknest-lightbox-swiper,
.linknest-lightbox-swiper :deep(.swiper-wrapper),
.linknest-lightbox-swiper :deep(.swiper-slide),
.linknest-lightbox-swiper :deep(.swiper-zoom-container) {
  height: 100%;
  width: 100%;
}

.linknest-lightbox-swiper {
  touch-action: none;
}
</style>
