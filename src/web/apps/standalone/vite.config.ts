import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// One self-contained dist/index.html, so the prototype opens without a server.
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  base: "./",
});
