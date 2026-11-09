export const SUPPORTED_PROTOCOL_VERSION = 4

export class MetadataError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'MetadataError'
    this.code = code
  }
}

export function validateMeta(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new MetadataError('INVALID_METADATA', '发起者返回的空间信息格式不正确。')
  }
  if (!Number.isInteger(value.protocolVersion)) {
    throw new MetadataError('INVALID_METADATA', '发起者未返回有效的协议版本。')
  }
  if (value.protocolVersion !== SUPPORTED_PROTOCOL_VERSION) {
    throw new MetadataError(
      'INCOMPATIBLE_PROTOCOL',
      `发起者协议版本为 ${value.protocolVersion}，当前 Web 仅支持版本 ${SUPPORTED_PROTOCOL_VERSION}。`,
    )
  }
  if (
    typeof value.spaceName !== 'string'
    || typeof value.visitorName !== 'string'
    || typeof value.hostVersion !== 'string'
    || !Array.isArray(value.capabilities)
    || value.capabilities.some((item) => typeof item !== 'string')
  ) {
    throw new MetadataError('INVALID_METADATA', '发起者返回的空间信息不完整。')
  }
  return value
}

export function isLivePhoto(file) {
  return file?.mediaType === 'livePhoto'
    && isResource(file?.resources?.photo)
    && isResource(file?.resources?.pairedVideo)
}

function isResource(value) {
  return value && typeof value === 'object' && typeof value.name === 'string'
}

export function fileBadge(file) {
  if (isLivePhoto(file)) return 'Live'
  const name = typeof file?.name === 'string' ? file.name : ''
  const dot = name.lastIndexOf('.')
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).toUpperCase() : ''
}

export function mediaUrl(file, variant, retry = 0) {
  const id = encodeURIComponent(file.id)
  const base = `/api/files/${id}/${variant}`
  const state = encodeURIComponent(file?.previewStatus || 'unknown')
  return retry > 0
    ? `${base}?state=${state}&retry=${retry}`
    : `${base}?state=${state}`
}

export function downloadResources(file) {
  const id = encodeURIComponent(file.id)
  const base = `/api/files/${id}/download`
  if (!isLivePhoto(file)) {
    return [{ label: '下载原文件', url: base, name: file.name }]
  }
  return [
    {
      label: '下载照片',
      url: base,
      name: file.resources.photo.name,
    },
    {
      label: '下载配对视频',
      url: `${base}?resource=pairedVideo`,
      name: file.resources.pairedVideo.name,
    },
  ]
}

export function previewState(file, loadFailed = false) {
  if (loadFailed) {
    return { canLoad: true, message: '预览加载失败', retryable: true }
  }
  if (file?.previewStatus === 'unsupported') {
    return { canLoad: false, message: '此格式暂不支持预览', retryable: false }
  }
  if (file?.previewStatus === 'failed') {
    return { canLoad: false, message: '预览生成失败', retryable: false }
  }
  if (file?.hasThumb === false) {
    return { canLoad: false, message: '无法预览', retryable: false }
  }
  return {
    canLoad: true,
    message: file?.previewStatus === 'unknown' ? '正在生成预览…' : '正在加载预览…',
    retryable: false,
  }
}

export function connectionMessage(error, { polling = false, authContext = 'session' } = {}) {
  if (error?.name === 'AbortError') return ''
  if (error?.code === 'INCOMPATIBLE_PROTOCOL') {
    return `${error.message} 请升级应用或使用与发起者匹配的版本。`
  }
  if (error?.status === 401 || error?.code === 'AUTH_REQUIRED') {
    return authContext === 'token'
      ? '空间码中的凭证无效或已过期，请扫描发起者当前显示的新空间码。'
      : '浏览器会话无效或已过期，请重新扫描发起者当前显示的空间码。'
  }
  if (error?.code === 'INVALID_METADATA' || error?.code === 'INVALID_RESPONSE') {
    return '发起者返回的数据格式不正确，请确认双方版本兼容。'
  }
  if (error instanceof TypeError || error?.code === 'NETWORK_ERROR') {
    return polling
      ? '与发起者的连接已中断，请确认仍连接到同一热点并检查发起者是否仍在共享。'
      : '无法连接发起者，请确认已连接到同一热点且发起者仍在共享。'
  }
  return error?.message || '连接发起者时发生未知错误。'
}
