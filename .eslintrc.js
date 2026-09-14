/**
 * Aturan lint proyek ini.
 *
 * Dipakai berkas .js, bukan .json, supaya alasannya bisa ditulis di sebelah
 * aturannya — JSON tidak bisa dikomentari, dan aturan tanpa alasan adalah
 * aturan yang dimatikan orang berikutnya begitu ia menghalangi.
 */
module.exports = {
  // next/typescript memuat plugin @typescript-eslint, yang tidak ikut
  // terpasang oleh core-web-vitals saja — tanpa itu aturan di bawah
  // ditolak sebagai "rule not found".
  extends: ['next/core-web-vitals', 'next/typescript'],
  rules: {
    // Dependensi hook diurus manual di proyek ini; sebagian efek memang
    // sengaja hanya berjalan pada kunci tertentu (mis. stop?.id).
    'react-hooks/exhaustive-deps': 'off',

    /*
     * Impor yang tidak terpakai bukan sekadar kerapian: ia sidik jari khas
     * sesuatu yang terhapus tanpa sengaja.
     *
     * Panel "HPP & Margin per Menu" pernah lenyap dari layar Belanja Bahan
     * karena satu penggantian blok JSX menelan pemanggilannya. Impornya
     * tertinggal, typecheck lolos, lint lolos, 26 berkas uji SQL lolos —
     * dan tidak ada satu pun pemeriksaan yang menyadari ada panel utuh yang
     * hilang. Yang menyadarinya pemakainya, setelah ia memakai layar itu.
     *
     * Berawalan garis bawah tetap diizinkan: itu penanda
     * sengaja-tidak-dipakai yang sudah umum dan memang ada gunanya.
     */
    '@typescript-eslint/no-unused-vars': ['error', {
      vars: 'all',
      args: 'after-used',
      argsIgnorePattern: '^_',
      varsIgnorePattern: '^_',
      caughtErrorsIgnorePattern: '^_',
      ignoreRestSiblings: true,
    }],
  },
}
