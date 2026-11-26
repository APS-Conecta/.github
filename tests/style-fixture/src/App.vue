<!-- SPDX-FileCopyrightText: 2026 APS Conecta -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<template>
	<div class="app">
		<!-- a commented-out <button> is not a button -->
		<NcButton variant="primary" @click="save">
			<template #icon>
				<span class="app__icon" />
			</template>
			Guardar
		</NcButton>
	</div>
</template>

<script>
export default {
	name: 'App',
	data: () => ({ unidad: { colour: '#e2007a' } }),
	methods: { save() {} },
}
</script>

<style scoped>
/* a hex in a comment, #fff, is not a colour */
.app {
	color: var(--color-main-text, #222222);
	background: var(--color-main-background, var(--color-background-plain, rgb(255 255 255)));
	font-size: var(--default-font-size);
	border: 1px solid var(--color-border);
}

.app__icon {
	font-size: 1.25rem;
}
</style>
