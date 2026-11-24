# GooglyEyes 👀

macOS menü çubuğunda duran, mouse'u takip eden googly gözler. Bölge ekran görüntüsü ve işaretleme aracı da içinde.

## Özellikler

**Gözler**
- Mouse'u yaylı bir fizikle takip eder; mouse iki gözün arasındayken birbirlerine bakarlar
- Ekranın herhangi bir yerinde sol tık sol gözü, sağ tık sağ gözü kırpar; basılı tutunca kapalı kalır
- Uyku: mouse bir süre hareket etmezse gözler kapanır ve "z Z Z" belirir
- Sallama: mouse'u hızla sağa sola sallayınca göz bebekleri çılgınca döner
- Rastgele davranışlar: göz kırpma, göz devirme, şaşı bakma, spiral göz bebekleri
- Şaşırma: ekran görüntüsü alırken ve panoya bir şey kopyalanınca göz bebekleri büyür
- Çöp kutusu korkusu: mouse Dock'taki çöp kutusunun üstündeyken ya da Çöp Sepeti açıkken göz bebekleri küçülür ve titrer (Erişilebilirlik izni gerekir)

**Ekran görüntüsü — ⌥⇧S**
- Bölge seçimi; birden fazla ekranda çalışır
- Kısayola basıldığı an ekran dondurulur; açık menüler/açılır pencereler kapansa bile görüntü o anın hali olur
- Menüden seçilir: sadece panoya ya da panoya + masaüstüne
- Yakalama ScreenCaptureKit ile yapılır (macOS 14+)

**WebP → PNG**
- İndirilenler ve Masaüstü'ne gelen yeni `.webp` dosyaları otomatik olarak aynı isimle `.png`'ye çevrilir; aslı Çöp Sepeti'ne gider
- Hareketli WebP'lere dokunulmaz · Menüden açılıp kapatılabilir

**İşaretleme**
- Gözlere tıkla → *Panodaki Görseli Aç ve İşaretle*
- Kalem, ok (sivri / yumuşak, düz / eğri), kutu, fosforlu kalem, yazı (Yuvarlak / Montserrat), numaralı işaret, pikselleştirme, bulanıklaştırma
- Silgi: bütün işareti ya da sadece dokunulan yeri siler
- Kırpma: kenar ve köşeleri sürükle, Enter ile uygula
- ⌘S: panoya kopyalar ve masaüstüne kaydeder · ⌘Z: geri alır

## Kurulum

Terminal'i aç ve şu satırı yapıştır:

```bash
curl -fsSL https://raw.githubusercontent.com/generece/GooglyEyes/main/install.sh | bash
```

Script son sürümü indirir, bu Mac'te derler, `~/Applications/GooglyEyes.app` olarak kurar ve başlatır.

- Bu Mac'te Xcode Command Line Tools yoksa Apple'ın kurulum penceresi açılır; "Yükle"ye bas, bitince komutu tekrar çalıştır.
- İlk kurulumda uygulamayı imzalamak için yerel bir sertifika oluşturulur; Mac şifren istenirse gir ve "Her Zaman İzin Ver"e bas. Bu sayede güncellemelerde izinler sıfırlanmaz.
- İlk ⌥⇧S'te **Ekran Kaydı** izni istenir: Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Ses Kaydı'nda GooglyEyes'ı aç, sonra uygulamayı yeniden başlat.

> ⌥⇧S başka bir uygulamada ya da Kestirmeler (Shortcuts) uygulamasında tanımlıysa çakışır; önce onu kaldır.

## Güncelleme

Gözlere tıkla → **Güncellemeleri Kontrol Et**. Yeni sürüm varsa tek tıkla indirilir, kurulur ve uygulama yeniden açılır. Uygulama açılışta ve günde bir kez kendisi de bakar; yeni sürüm varsa menüde **✨ Güncelleme Var** yazar.

Kaynak koddan elle derlemek için: `bash build.sh`

## Gereksinimler

- macOS 12+ (ekran görüntüsünün ScreenCaptureKit ile alınması için macOS 14+)
- Apple Silicon veya Intel

## Dosyalar

| Dosya | Açıklama |
|---|---|
| `main.swift` | Uygulamanın tamamı (AppKit) |
| `build.sh` | Derleme, imzalama, kurulum |
| `Info.plist` | Uygulama bilgileri |
| `Resources/` | Göz dokuları (göz akı, göz bebeği, parlama, kapak, spiral), ikon ve Montserrat Bold (SIL Open Font License, `Montserrat-OFL.txt`) |
