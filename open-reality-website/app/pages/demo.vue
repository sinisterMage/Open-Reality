<script setup lang="ts">
useSeoMeta({
  title: 'Demo - OpenReality',
  ogTitle: 'OpenReality Demo - Play in Browser',
  description: 'Play the OpenReality dungeon crawler demo directly in your browser using WebGPU.',
  ogDescription: 'Play the OpenReality dungeon crawler demo directly in your browser using WebGPU.',
})

const status = ref('Checking WebGPU support...')
const error = ref('')
const loading = ref(true)
const canvasRef = ref<HTMLCanvasElement | null>(null)

let app: any = null

onMounted(async () => {
  if (!navigator.gpu) {
    error.value = 'WebGPU is not supported in this browser. Please use Chrome 113+, Edge 113+, or a browser with WebGPU enabled.'
    loading.value = false
    return
  }

  try {
    status.value = 'Loading WASM runtime...'
    // Use dynamic URL to bypass Vite's module processing
    const wasmUrl = '/demo/openreality_web.js'
    const mod = await import(/* @vite-ignore */ wasmUrl)
    const init = mod.default
    const create_app = mod.create_app
    await init()

    status.value = 'Loading scene...'
    const resp = await fetch('/demo/scene.orsb')
    if (!resp.ok) throw new Error(`Failed to fetch scene: ${resp.status}`)
    const data = new Uint8Array(await resp.arrayBuffer())

    const canvas = canvasRef.value!
    canvas.width = window.innerWidth
    canvas.height = window.innerHeight

    status.value = 'Initializing renderer...'
    app = await create_app('demo-canvas', data)

    loading.value = false

    // Resize handler
    window.addEventListener('resize', () => {
      canvas.width = window.innerWidth
      canvas.height = window.innerHeight
      app?.resize(canvas.width, canvas.height)
    })

    // Game loop
    function loop(time: number) {
      app?.frame(time)
      requestAnimationFrame(loop)
    }
    requestAnimationFrame(loop)
  } catch (e: any) {
    error.value = `Failed to start: ${e.message || e}`
    loading.value = false
  }
})

onUnmounted(() => {
  app = null
})

function goBack() {
  navigateTo('/')
}
</script>

<template>
  <div class="fixed inset-0 bg-black">
    <!-- Loading overlay -->
    <div
      v-if="loading && !error"
      class="absolute inset-0 flex flex-col items-center justify-center bg-or-bg z-20"
    >
      <div class="w-10 h-10 border-2 border-or-border border-t-or-green rounded-full animate-spin mb-4" />
      <p class="font-mono text-or-text-dim text-sm">{{ status }}</p>
    </div>

    <!-- Error overlay -->
    <div
      v-if="error"
      class="absolute inset-0 flex flex-col items-center justify-center bg-or-bg z-20 px-6"
    >
      <p class="font-mono text-red-400 text-center max-w-lg mb-6">{{ error }}</p>
      <button
        class="px-6 py-2 border border-or-border font-mono text-sm text-or-text-dim hover:text-or-green hover:border-or-green rounded transition-all"
        @click="goBack"
      >
        Back to Home
      </button>
    </div>

    <!-- Game canvas -->
    <canvas
      id="demo-canvas"
      ref="canvasRef"
      class="w-full h-full block"
      :class="{ 'opacity-0': loading || !!error }"
    />

    <!-- Escape hint -->
    <div
      v-if="!loading && !error"
      class="absolute top-4 right-4 z-10 font-mono text-xs text-or-text-dim/50 pointer-events-none"
    >
      ESC to release mouse
    </div>
  </div>
</template>
