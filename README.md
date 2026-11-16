# WattWhat ⚡️

Pure Swift ile geliştirilmiş gelişmiş macOS menü çubuğu güç izleme ve aktif şarj watt kontrol uygulaması. MacBook'unuzun anlık şarj gücünü (Watt), uygulama bazlı enerji tüketimini, pil/CPU sıcaklıklarını takip edebilir ve istediğiniz zaman şarj gücünü manuel Watt seviyesine (5 W – 140 W) ya da otomatik macOS yönetimine alabilirsiniz.

## Özellikler

- **Aktif Şarj Watt Kontrolü (5 W – 140 W):** MacBook'unuzu ister otomatik macOS yönetiminde bırakın, ister net pil şarj gücünü veya toplam adaptör çekiş limitini kendiniz belirleyin (`5W Gece`, `10W Serin`, `15W Dengeli`, `20W Standart`, `30W Hızlı`, `45W`, `67W`, `96W+` veya 5–140 W arası herhangi bir tam sayı).
- **Şarj & Güç Stüdyosu (`⌘P`):** Sağ üst menü ikonunun hemen içinden açılan birleşik kontrol merkezi ile canlı `Adaptör ➔ Sistem Yükü + Pil Akışı` şemasını, aktif USB-PD PDO profillerini, 4 çalışma modunu ve AppleSMC donanım matrisini yönetin.
- **Adaptörde Beklet (0W Passthrough) & Yelken/Deşarj Modu:** Pili doldurmayı durdurup yalnızca prizden çalışabilir (`0W`) veya fişe takılıyken belirlediğiniz pil yüzdesine (`%20–%90`) kadar güvenli biçimde deşarj edebilirsiniz (`%15` güvenlik kilidi ile).
- **Pil Şarj Tavanı, Histerezis & Tek Seferlik %100 (Top-Up):** `%50–%100` arası şarj tavanı ve histerezis korumasını ayarlayın; seyahat öncesi tek tıkla "Bugünlük %100 Doldur" modunu açın.
- **3 Kademeli Özel Şarj Eğrisi & Akıllı Otomasyon:** Pil yüzdesine göre (`%0–50`, `%50–80`, `%80–100`) kademeli Watt düşüşü tanımlayın; otomatik termal kısma, gece sessiz/soğuk şarj penceresi, şarja takılma davranışı ve MagSafe 3 LED kontrolünü (`Otomatik`, `Yeşil`, `Turuncu`, `Kapalı`) özelleştirin.
- **Yetkili Güç Motoru (`wattwhat-helper`) & `wattctl` CLI:** `AppleSMC` yazma işlemlerini güvenli bir `LaunchDaemon` servisi üzerinden yürütür, fabrika başlangıç değerlerini yedekler ve `wattctl` terminal aracıyla tam kontrol sağlar.
- **Canlı Güç & Uygulama Bazlı Enerji İzleme:** `IOKit` / `AppleSmartBattery` verileriyle anlık Watt, 3 sn / 30 sn / 5 dk uygulama enerji sıralaması, 7 günlük grafikler ve CSV dışa aktarma sunar.
- **Akıllı Uyarılar & Başlangıçta Aç:** Pil %20 / %80 / %100 bildirimleri, yüksek sıcaklık ve yoğun tüketim uyarıları ile native `SMAppService` otomatik başlatma desteği içerir.

## Kurulum ve Kullanım

### Uygulamayı Derleme ve Kurma

```bash
swift test
./build.swift
```

Derleme çıktısı olan `WattWhat.app` paketini `/Applications/WattWhat.app` konumuna taşıyıp açtığınızda (veya `./install.sh` betiğini çalıştırdığınızda) sağ üst menü çubuğunda aktif olur. İlk manuel watt veya tavan kontrolü sırasında uygulama, arka plan güç motorunu (`com.kuarezma.wattwhat.helper`) kurmak için bir kez macOS yönetici onayı (Touch ID / şifre) ister.

## Komut Satırı Aracı (`wattctl`)

`/usr/local/bin/wattctl` komutu, uygulama içindeki **"Yetkili Güç Motorunu Etkinleştir"** adımıyla (veya doğrudan `/Applications/WattWhat.app/Contents/MacOS/wattctl install` komutuyla) `PATH`'e otomatik olarak kurulur.

```bash
wattctl status                 # Canlı güç akışı ve USB-PD PDO profilleri
wattctl status --json          # Güç akışı ve yapılandırmayı JSON formatında yazdır
wattctl auto                   # macOS otomatik yönetimine devret
wattctl watt 15                # Net 15 W ile şarj et
wattctl watt 25 --adapter      # Toplam adaptör çekişini 25 W ile sınırla
wattctl passthrough            # Şarjı durdur (0 W), fişten çalış
wattctl discharge 60           # Fişteyken %60'a kadar pilden tüket
wattctl limit 80               # Maksimum şarj tavanını %80 yap
wattctl topup                  # Tek seferlik %100'e tamamla
wattctl led green              # MagSafe LED (auto | green | amber | off)
wattctl lpm on                 # macOS Düşük Güç Modunu aç (on | off)
wattctl probe                  # Canlı AppleSMC donanım anahtar matrisi
wattctl install                # Yetkili güç motorunu ve /usr/local/bin/wattctl aracını kur
wattctl uninstall              # Yetkili servisi kaldır ve fabrika ayarlarına dön
```

## Gereksinimler

- macOS 13.0 (Ventura) veya üzeri
- Gelişmiş AppleSMC şarj kontrolü ve IOHID işlemci sıcaklığı sensörleri **Apple Silicon (M1/M2/M3/M4)** mimarisi için optimize edilmiştir
- MIT Lisansı
