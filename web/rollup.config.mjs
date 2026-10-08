import resolve from '@rollup/plugin-node-resolve';
import typescript from '@rollup/plugin-typescript';
import terser from '@rollup/plugin-terser';

export default [
  {
    input: 'src/index.ts',
    output: {
      file: 'dist/index.esm.js',
      format: 'es',
      sourcemap: true,
    },
    plugins: [
      resolve(),
      typescript({
        tsconfig: './tsconfig.json',
        declarationDir: './dist',
        outputToFilesystem: true,
      }),
      terser(),
    ],
  },
  {
    input: 'src/umd-entry.ts',
    output: {
      file: 'dist/index.umd.js',
      format: 'umd',
      name: 'MobyBeacon',
      exports: 'default',
      sourcemap: true,
    },
    plugins: [
      resolve(),
      typescript({
        tsconfig: './tsconfig.json',
        compilerOptions: { declaration: false, declarationMap: false },
      }),
      terser(),
    ],
  },
];
