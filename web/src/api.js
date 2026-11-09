export class ApiError extends Error {
  constructor(message, { code = 'REQUEST_FAILED', status = 0 } = {}) {
    super(message)
    this.name = 'ApiError'
    this.code = code
    this.status = status
  }
}

// 服务端接口封装：统一解包 {ok, data, error}
async function request(path, options = {}) {
  const res = await fetch(path, { credentials: 'same-origin', ...options })
  const body = await res.json().catch(() => null)
  if (!body || typeof body !== 'object') {
    throw new ApiError(`HTTP ${res.status} 返回了无效数据`, {
      code: 'INVALID_RESPONSE',
      status: res.status,
    })
  }
  if (!res.ok || !body.ok) {
    throw new ApiError(body.message || body.error || `HTTP ${res.status}`, {
      code: body.code || 'REQUEST_FAILED',
      status: res.status,
    })
  }
  return body.data
}

async function establishSession() {
  const fragment = new URLSearchParams(window.location.hash.slice(1))
  const token = fragment.get('token')
  if (!token) return { usedToken: false }
  try {
    await request('/api/web-session', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
    })
  } catch (error) {
    error.authContext = 'token'
    throw error
  }
  history.replaceState(history.state, '', `${location.pathname}${location.search}`)
  return { usedToken: true }
}

// 上传带进度：fetch 无法监听上传进度，改用 XMLHttpRequest。
// onProgress(0-100) 在上传过程中回传；resolve 的是服务端返回的新文件元数据数组。
function upload(formData, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', '/api/upload')
    xhr.withCredentials = true
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) {
        onProgress(Math.round((e.loaded / e.total) * 100))
      }
    }
    xhr.onload = () => {
      try {
        const body = JSON.parse(xhr.responseText)
        if (xhr.status === 200 && body.ok) resolve(body.data)
        else reject(new ApiError(body.message || body.error || `HTTP ${xhr.status}`, {
          code: body.code || 'UPLOAD_FAILED',
          status: xhr.status,
        }))
      } catch {
        reject(new ApiError(`HTTP ${xhr.status} 返回了无效数据`, {
          code: 'INVALID_RESPONSE',
          status: xhr.status,
        }))
      }
    }
    xhr.onerror = () => reject(new ApiError('网络错误', { code: 'NETWORK_ERROR' }))
    xhr.send(formData)
  })
}

export const api = {
  establishSession,
  meta: () => request('/api/meta'),
  files: (signal) => request('/api/files', { signal }),
  upload,
}
