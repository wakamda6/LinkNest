import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  // 相对路径，便于 Host 服务端从根路径 serve
  base: './',
  plugins: [vue(), tailwindcss()],
  build: {
    rollupOptions: {
      output: {
        // 文件保持平铺，确保 Flutter rootBundle 能收录；内容 hash 用于隔离旧浏览器缓存。
        entryFileNames: '[name]-[hash].js',
        chunkFileNames: '[name]-[hash].js',
        assetFileNames: '[name]-[hash].[ext]',
      },
    },
  },
})
