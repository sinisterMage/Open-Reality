// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2025-07-15',
  devtools: { enabled: true },
  modules: ['@nuxtjs/tailwindcss'],
  css: ['~/assets/css/main.css'],
  site: {
    url: 'https://openreality.dev',
    name: 'OpenReality',
  },
  app: {
    head: {
      htmlAttrs: { lang: 'en' },
      title: 'OpenReality - Julia Game Engine',
      meta: [
        { name: 'description', content: 'Declarative code-first game engine built in Julia with ECS architecture, PBR rendering, physics, and 4 GPU backends.' },
        { name: 'theme-color', content: '#0a0e14' },
        { name: 'robots', content: 'index, follow' },
        { name: 'author', content: 'OpenReality Contributors' },
        { name: 'keywords', content: 'Julia, game engine, ECS, PBR, Vulkan, Metal, OpenGL, WebGPU, physics, rendering, open source' },
        // Open Graph
        { property: 'og:type', content: 'website' },
        { property: 'og:site_name', content: 'OpenReality' },
        { property: 'og:title', content: 'OpenReality - Julia Game Engine' },
        { property: 'og:description', content: 'Declarative code-first game engine built in Julia with ECS architecture, PBR rendering, physics, and 4 GPU backends.' },
        // Twitter Card
        { name: 'twitter:card', content: 'summary_large_image' },
        { name: 'twitter:title', content: 'OpenReality - Julia Game Engine' },
        { name: 'twitter:description', content: 'Declarative code-first game engine built in Julia with ECS architecture, PBR rendering, physics, and 4 GPU backends.' },
      ],
      link: [
        { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
        { rel: 'preconnect', href: 'https://fonts.gstatic.com', crossorigin: '' },
        { rel: 'stylesheet', href: 'https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&family=Inter:wght@400;500;600;700&display=swap' },
      ],
      script: [
        {
          type: 'application/ld+json',
          innerHTML: JSON.stringify({
            '@context': 'https://schema.org',
            '@type': 'SoftwareSourceCode',
            name: 'OpenReality',
            description: 'Declarative code-first game engine built in Julia with ECS architecture, PBR rendering, physics, and 4 GPU backends.',
            programmingLanguage: 'Julia',
            codeRepository: 'https://github.com/sinisterMage/Open-Reality',
            license: 'https://opensource.org/licenses/MIT',
            applicationCategory: 'Game Engine',
            operatingSystem: 'Linux, macOS, Windows',
          }),
        },
      ],
    },
  },
})