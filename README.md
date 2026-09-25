# Selda Gençer Beauty — native iOS telsiz

Bundle `com.rootbeauty.app` (mağazadaki canlı sürüm 1.9; bu proje **2.0**).
Saf SwiftUI + PushToTalk; React Native yok. EAS, `ios/` içindeki Xcode
projesini özel derleme (custom build) ile doğrudan derler.

## Düzen

```
package.json / app.json / eas.json     EAS'ın projeyi tanıması için
.eas/build/ios-store.yml               bulut derleme adımları (fastlane gym)
ios/project.yml                        Xcode projesinin kaynağı (XcodeGen)
ios/BeautyRadio.xcodeproj              project.yml'den üretilmiş, depoda
ios/BeautyRadio/Sources/*.swift        uygulama kodu (tek doğruluk kaynağı)
ios/BeautyRadio/Info.plist             project.yml'den üretilir
ios/BeautyRadio/BeautyRadio.entitlements
ios/BeautyRadioTests/                  protokol testleri
```

Kaynak dosyayı ekler/çıkarırsan `project.yml`'i güncelleyip projeyi yeniden üret:
`xcodegen generate --spec ios/project.yml`.

## Derleme

```bash
export EXPO_TOKEN=...                 # expo.dev -> Account -> Access tokens
npx eas build --platform ios --profile production   # mağaza/TestFlight
npx eas build --platform ios --profile device       # cihaza kurulum (internal)
```

İlk derlemede EAS, Apple dağıtım sertifikası ve profil üretir. Etkileşimsiz
ortamda bunun için App Store Connect API anahtarı gerekir:

```bash
export EXPO_APPLE_TEAM_ID=39GA2BR55U
export EXPO_ASC_KEY_ID=66D424RX7V          # sunucudaki AuthKey_66D424RX7V.p8
export EXPO_ASC_ISSUER_ID=...              # App Store Connect -> Integrations
export EXPO_ASC_API_KEY_PATH=/yol/AuthKey_66D424RX7V.p8
```

`com.rootbeauty.app` App ID'sinde **Push to Talk** ve **Push Notifications**
yetenekleri açık olmalı (mevcut uygulama zaten kullanıyor).

## Doğrulanmış olanlar

| Ne | Nasıl |
|---|---|
| BRAD tel formatı sunucuyla birebir | `swift test` — backend `radioBackend.test.js` fixture'ının aynısı, bayt bayt |
| İndirme başlığının farklı uzunluğu | ayrı test; eski derlemeyi sessiz bırakan hata buydu |
| Eşzamanlılık / aktör izolasyonu | tüm kaynaklar Linux'ta **Swift 6 katı modunda sıfır uyarı** ile derlendi (SwiftUI/WebKit kabuğu hariç) |
| Ön-tampon: basıştan önceki hece gider | `./linux-check/run.sh` |
| Kuyruk: bırakıştan sonraki kare gider, stop beklenir | `./linux-check/run.sh` |
| Token süresi kararı (reboot sonrası ilk basış) | `./linux-check/run.sh` |
| Sunucu ses yolu | `npm run doctor:radio-e2e` — 50/50 kare, ~30 ms |
| Kalıcı oturum (web) | `npm run doctor:session-browser` — gerçek Chromium, 7 senaryo |

`linux-check/` Mac olmadan çalışır: uygulama kaynaklarını Apple çerçevelerinin
küçük taklitlerine karşı derler ve saf mantığı test eder. Gerçek SDK davranışını
kanıtlamaz; tip/eşzamanlılık hatalarını bulut derlemesi yerine saniyeler içinde
yakalamak içindir.

```bash
./linux-check/run.sh          # 8 test
```

**Derlenmemiş olan:** bu sunucuda macOS/Xcode yok. SwiftUI ve WebKit kullanan
iki dosya (`BeautyRadioApp.swift`, `RadioView.swift`) yalnızca sözdizimi
denetiminden geçti. İlk bulut derlemesi küçük düzeltmeler isteyebilir.

## Tasarım kararları

**Tuşa basış hiçbir iş yapmaz.** Ses motoru kanala katılırken hazırlanır; basış
yalnızca bir bayrak çevirir. Önceki derlemede tuştan ilk ses baytına **871 ms
(ortanca), en kötü 2719 ms** ölçülmüştü; sunucu payı 25–44 ms.

**Ön-tampon (300 ms).** Motor sürekli çalıştığı için basıştan hemen önce
söylenen hece de gönderilir.

**Kuyruk (250 ms).** Bırakışta `ptt-stop` hemen gönderilmez: motor 250 ms daha
yakalar, yarım kareyi sıfırla doldurup yollar, stop ondan sonra gider. Sunucu da
bırakış sonrası 250 ms aynı konuşmacıyı kabul eder (`RADIO_TAIL_GRACE_MS`).
"Hızlıca şunu söyleyeyim" cümlesinin son kelimesi böyle kurtarıldı.

**Meşgul durumu yok.** Sunucu her `ptt-granted` içinde
`allowConcurrentTalk: true, busy: false` gönderir; butonu devre dışı bırakan tek
satır yoktur.

**Ses oturumu sahipliği.** PushToTalk ile oturumu **sistem** aktive eder.
`prepare()` oturumu talep etmeden her şeyi kurar; `activate()` uygulama
öndeyken, `resumeAfterSystemActivation()` sistem devrettiğinde çağrılır. Ekran
kapalıyken tuşun anında çalışmasının şartı budur.

**Bluetooth önceliği.** `.playAndRecord` + `.voiceChat` +
`[.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]`; rota
değişiminde bağlı kulaklık yeniden `preferredInput` yapılır.

**Kalıcı oturum.** Giriş `client: "ios"` ile yapılır ve dönen yenileme token'ı
Keychain'de (`AfterFirstUnlockThisDeviceOnly`) saklanır — telefon kilitliyken
gelen APNs uyanışında da okunabilir. 4 saatlik JWT açılışta, 401'de ve periyodik
olarak yenilenir. Panel sekmesindeki WKWebView'e aynı çerezler aktarılır, böylece
web paneli de tekrar giriş istemez. Token kullanımda döndürülmediği için native
ile panelin aynı token'ı paylaşması kilitlenmeye yol açmaz.

**Arka planda uyanma.** `PTChannelManager` uygulama açılışında oluşturulur, bir
görünüm çizildiğinde değil: PTT bildirimi kapalı uygulamayı arka planda
başlattığında hiçbir görünüm çizilmeyebilir. `incomingPushResult` ve
`didJoinChannel` yollarının ikisi de kanala yeniden katılır.
