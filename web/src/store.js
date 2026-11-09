import { reactive } from 'vue'

// 全局状态（简单 reactive，无 Pinia）
export const store = reactive({
  meta: { spaceName: '', visitorName: '' },
  files: [],
  uploading: false,
  uploadProgress: 0, // 0-100
  error: '',
  connectionWarning: '',
  lightboxFile: null,
  // 内联轻偏好（随会话走，不持久化）
  sort: 'newest', // newest | oldest
  grid: 3, // 2 | 3 | 4（宫格列数）
  dark: false,
  // 展示维度
  mode: 'default', // default | uploader
  activeUploader: null, // 上传者模式：null = 分组列表；字符串 = 只看该上传者
})

// 按上传时间排序（sort: 'newest' | 'oldest'）。画廊与 Lightbox 共用，保证顺序一致。
export function sortFiles(list, sort = 'newest') {
  return [...list].sort((a, b) =>
    sort === 'oldest' ? a.uploadedAt - b.uploadedAt : b.uploadedAt - a.uploadedAt,
  )
}

// 画廊和 Lightbox 必须从同一份过滤、排序结果导航，避免轮询刷新后索引错位。
export function visibleFiles() {
  const list = store.activeUploader
    ? store.files.filter((f) => f.uploader === store.activeUploader)
    : store.files
  return sortFiles(list, store.sort)
}
