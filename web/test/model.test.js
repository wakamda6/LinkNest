import assert from 'node:assert/strict'
import test from 'node:test'

import {
  connectionMessage,
  downloadResources,
  fileBadge,
  isLivePhoto,
  mediaUrl,
  MetadataError,
  previewState,
  validateMeta,
} from '../src/model.js'

const livePhoto = {
  id: 'live id',
  name: 'IMG_0001.HEIC',
  mediaType: 'livePhoto',
  previewStatus: 'ready',
  hasThumb: true,
  resources: {
    photo: { name: 'IMG_0001.HEIC' },
    pairedVideo: { name: 'IMG_0001.MOV' },
  },
}

test('accepts complete protocol v4 metadata', () => {
  const meta = {
    spaceName: '旅行',
    visitorName: '访客 1',
    protocolVersion: 4,
    hostVersion: '1.0.0',
    capabilities: ['livePhotoV1'],
  }
  assert.equal(validateMeta(meta), meta)
})

test('rejects incompatible and malformed metadata', () => {
  assert.throws(
    () => validateMeta({ protocolVersion: 2 }),
    (error) => error instanceof MetadataError && error.code === 'INCOMPATIBLE_PROTOCOL',
  )
  assert.throws(
    () => validateMeta({ protocolVersion: 4 }),
    (error) => error instanceof MetadataError && error.code === 'INVALID_METADATA',
  )
})

test('recognizes Live Photo and exposes both original resources', () => {
  assert.equal(isLivePhoto(livePhoto), true)
  assert.equal(fileBadge(livePhoto), 'Live')
  assert.deepEqual(downloadResources(livePhoto), [
    {
      label: '下载照片',
      url: '/api/files/live%20id/download',
      name: 'IMG_0001.HEIC',
    },
    {
      label: '下载配对视频',
      url: '/api/files/live%20id/download?resource=pairedVideo',
      name: 'IMG_0001.MOV',
    },
  ])
})

test('keeps extension badge and one download for ordinary media', () => {
  const video = { id: 'video', name: 'clip.mov' }
  assert.equal(fileBadge(video), 'MOV')
  assert.deepEqual(downloadResources(video), [
    { label: '下载原文件', url: '/api/files/video/download', name: 'clip.mov' },
  ])
})

test('distinguishes preview states and runtime retry', () => {
  assert.equal(previewState({ previewStatus: 'unknown', hasThumb: true }).message, '正在生成预览…')
  assert.equal(previewState({ previewStatus: 'unsupported' }).message, '此格式暂不支持预览')
  assert.equal(previewState({ previewStatus: 'failed' }).message, '预览生成失败')
  assert.deepEqual(previewState({ previewStatus: 'ready' }, true), {
    canLoad: true,
    message: '预览加载失败',
    retryable: true,
  })
})

test('changes media URL when preview state becomes ready', () => {
  const file = { id: 'new file', previewStatus: 'unknown' }
  assert.equal(
    mediaUrl(file, 'thumbnail'),
    '/api/files/new%20file/thumbnail?state=unknown',
  )
  assert.equal(
    mediaUrl({ ...file, previewStatus: 'ready' }, 'thumbnail'),
    '/api/files/new%20file/thumbnail?state=ready',
  )
  assert.equal(
    mediaUrl({ ...file, previewStatus: 'ready' }, 'thumbnail', 1),
    '/api/files/new%20file/thumbnail?state=ready&retry=1',
  )
})

test('maps authentication, network and protocol failures to actionable messages', () => {
  assert.match(connectionMessage({ code: 'AUTH_REQUIRED', status: 401 }), /浏览器会话/)
  assert.match(
    connectionMessage({ code: 'AUTH_REQUIRED', status: 401 }, { authContext: 'token' }),
    /空间码中的凭证/,
  )
  assert.match(connectionMessage(new TypeError('Failed to fetch'), { polling: true }), /连接已中断/)
  assert.match(
    connectionMessage(new MetadataError('INCOMPATIBLE_PROTOCOL', '协议不兼容')),
    /升级应用/,
  )
})
