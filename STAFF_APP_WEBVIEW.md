# Staff ilovasi (WebView) — Provodka chek yuklash ishlashi uchun talablar

Muammo (2026-08-31): Provodka `hodim.html` staff ilovasi ichida WebView bo'lib ochiladi.
Chek yuklash tugmasi `<input type="file" accept="image/*">` — **Android WebView'da bu
faqat ilova `onShowFileChooser`ni implement qilgan bo'lsa ishlaydi**. Hozir bosilganda
hech narsa bo'lmayapti (xatosiz, jimgina) — bu aynan handler yo'qligining belgisi.
Web tomondan aylanib o'tishning iloji YO'Q.

## Android (majburiy)

1. `WebChromeClient` da fayl tanlagichni ochish:

```kotlin
webView.webChromeClient = object : WebChromeClient() {
    override fun onShowFileChooser(
        view: WebView, callback: ValueCallback<Array<Uri>>,
        params: FileChooserParams
    ): Boolean {
        filePathCallback?.onReceiveValue(null)
        filePathCallback = callback
        // Kamera + galereya BIRGA taklif qilinsin:
        val camera = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            cameraUri = createImageUri()           // FileProvider orqali
            putExtra(MediaStore.EXTRA_OUTPUT, cameraUri)
        }
        val gallery = params.createIntent()        // ACTION_GET_CONTENT image/*
        val chooser = Intent.createChooser(gallery, "Chek yuklash").apply {
            putExtra(Intent.EXTRA_INITIAL_INTENTS, arrayOf(camera))
        }
        fileChooserLauncher.launch(chooser)        // natijada callback.onReceiveValue(uris)
        return true
    }
}
```

2. Manifest + runtime:
   - `<uses-permission android:name="android.permission.CAMERA"/>` + runtime so'rov
   - Kamera surati uchun `FileProvider` (`EXTRA_OUTPUT` uri shu orqali)
   - Natija kelmasa/bekor bo'lsa ham `callback.onReceiveValue(null)` chaqirilsin —
     aks holda keyingi bosishlar ishlamay qoladi.

3. WebView sozlamalari (tekshirish): `javaScriptEnabled=true`, `domStorageEnabled=true`
   (Provodka localStorage/sessionStorage ishlatadi — busiz login ham buziladi).

## iOS (tekshirish)

WKWebView'da file input o'z-o'zidan ishlaydi, faqat Info.plist kalitlari bo'lsin:
- `NSCameraUsageDescription`
- `NSPhotoLibraryUsageDescription`

## Tarmoq

Sahifa `https://kxzerccdpcltmzrxutlo.supabase.co` ga fetch qiladi. WebView'da
so'rovlarni cheklaydigan filtr/interceptor bo'lsa, shu domen (va `pravodka.com`)
ruxsat etilgan bo'lsin. ("TypeError: Load failed" xatosi ko'rilgan edi — u
2026-08-31 dagi DB qulf hodisasiga to'g'ri keladi, lekin filtr ham tekshirilsin.)

## Qabul testi

1. Ilova ichida hodim.html ochiladi → chek tugmasi bosilganda **Kamera/Galereya
   tanlovi** chiqadi (ikkalasi ham).
2. Kameradan olingan rasm ham, galereyadan tanlangani ham preview'da ko'rinadi
   va saqlashda yuklanadi.
3. Ruxsat rad etilgan holatda ham tugma "jim" qolmasin — ruxsat so'rovi chiqsin.
