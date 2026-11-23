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
- Görüntü panoya kopyalanır ve masaüstüne kaydedilir
- Yakalama ScreenCaptureKit ile yapılır (macOS 14+)

**İşaretleme**
- Gözlere tıkla → *Panodaki Görseli Aç ve İşaretle*
- Kalem, ok, kutu, fosforlu kalem, yazı, numaralı işaret, pikselleştirme, bulanıklaştırma
- ⌘S: panoya kopyalar ve masaüstüne kaydeder · ⌘Z: geri alır

## Kurulum

Gereken tek şey Xcode Command Line Tools (yoksa script kurulumu kendisi başlatır).

```bash
bash build.sh
```

Script uygulamayı derler, sabit bir yerel sertifikayla imzalar (böylece Ekran Kaydı izni her derlemede sıfırlanmaz), `~/Applications/GooglyEyes.app` olarak kurar ve başlatır.

İlk ⌥⇧S'te **Ekran Kaydı** izni istenir: Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Ses Kaydı'nda GooglyEyes'ı aç, sonra uygulamayı yeniden başlat.

> ⌥⇧S başka bir uygulamada ya da Kestirmeler (Shortcuts) uygulamasında tanımlıysa çakışır; önce onu kaldır.

## Gereksinimler

- macOS 12+ (ekran görüntüsünün ScreenCaptureKit ile alınması için macOS 14+)
- Apple Silicon veya Intel

## Dosyalar

| Dosya | Açıklama |
|---|---|
| `main.swift` | Uygulamanın tamamı (AppKit) |
| `build.sh` | Derleme, imzalama, kurulum |
| `Info.plist` | Uygulama bilgileri |
| `Resources/` | Göz dokuları (göz akı, göz bebeği, parlama, kapak, spiral) ve ikon |
