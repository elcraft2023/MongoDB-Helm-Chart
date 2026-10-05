# MongoDB Helm Chart

Ein anpassbares Helm Chart für ein MongoDB Replica Set auf Kubernetes. Es richtet standardmäßig drei MongoDB-Mitglieder mit TLS, interner Replica-Set-Authentifizierung, dauerhaftem Speicher und optionalen Backups ein.

> **Hinweis zu Geheimnissen:** Keine Passwörter, privaten Schlüssel, Zertifikate oder Kubernetes-Secret-Inhalte committen. Das MongoDB-Administratorpasswort wird direkt aus HashiCorp Vault durch den Vault Agent Injector in die Pods eingebunden. Es steht weder in Helm-Values noch in einem Kubernetes-Secret. TLS- und Keyfile-Material werden weiterhin als Kubernetes-Secrets bereitgestellt.

## Inhalt

- [Architektur und Funktionen](#architektur-und-funktionen)
- [Voraussetzungen und Start](#voraussetzungen-und-start)
- [Anpassungen](#anpassungen)
- [Secrets und Passwörter](#secrets-und-passwörter)
- [Backups und Wiederherstellung](#backups-und-wiederherstellung)
- [Ressourcen und mehrere Server](#ressourcen-und-mehrere-server)
- [HashiCorp Vault](#hashicorp-vault)
- [Prüfungen und bekannte Grenzen](#prüfungen-und-bekannte-grenzen)

## Architektur und Funktionen

Das Chart enthält:

- Einen `StatefulSet` für standardmäßig drei MongoDB-Pods (`mongodb-0` bis `mongodb-2`).
- Ein Headless Service für stabile DNS-Namen der Pods.
- Ein eigenes dauerhaftes Volume pro MongoDB-Pod.
- Individuelle TLS-Zertifikate pro Mitglied und eine gemeinsame CA.
- Eine Keyfile-basierte interne Authentifizierung zwischen Replica-Set-Mitgliedern.
- Einen Bootstrap-Job, der das Replica Set initialisiert.
- Einen optionalen Backup-CronJob mit eigenem persistentem Backup-Volume.
- Einen optionalen Restore-Job, der ein ausgewähltes Archiv wiederherstellt.
- Konfigurierbare Ressourcen und Regeln zur Pod-Platzierung.

## Voraussetzungen und Start

Benötigt werden ein Kubernetes-Cluster, `kubectl`, Helm, HashiCorp Vault mit aktiviertem Vault Agent Injector und Vault Secrets Operator. Für den lokalen Versuch wurde Minikube verwendet. Die Vault-Kubernetes-Authentifizierung, das Vault-KV-Passwort sowie TLS- und Keyfile-Werte müssen vorbereitet sein. Details dazu stehen in [`vault/README.md`](vault/README.md).

Wende die Vault-Ressourcen an und warte, bis die TLS- und Keyfile-Secrets synchronisiert sind. Das Administratorpasswort bleibt in Vault und wird nicht lokal in einer Datei abgelegt.

```bash
minikube start
kubectl create namespace mongodb
kubectl apply -f vault/vso-mongodb.yaml
helm lint ./mongodb-chart
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb \
  --reset-values \
  --wait \
  --timeout 10m
```

Status prüfen:

```bash
kubectl get pods,services,pvc,cronjob -n mongodb
kubectl rollout status statefulset/mongodb -n mongodb --timeout=5m
```

Für ein bereits laufendes Minikube-Profil genügt `minikube start`. Bei einem anderen Release-Namen, Namespace oder DNS-Namen müssen die Zertifikate passende Subject Alternative Names enthalten.

### Start unter Windows (PowerShell)

Öffne PowerShell und wechsle in den Projektordner. Passe den Beispielpfad an den Speicherort deines Klons an:

```powershell
Set-Location "C:\Pfad\zu\mongodb-projekt"
minikube start
kubectl create namespace mongodb
kubectl apply -f .\vault\vso-mongodb.yaml
helm lint .\mongodb-chart
helm upgrade --install mongodb .\mongodb-chart --namespace mongodb --reset-values --wait --timeout 10m
```

Die Statusbefehle ohne Bash-Zeilenfortsetzung funktionieren in PowerShell unverändert. Vor dem Helm-Install müssen Vault Agent Injector und VSO bereit sowie die TLS- und Keyfile-Secrets synchronisiert sein.


## Anpassungen

Die Standardwerte und ihre Kommentare stehen in [`mongodb-chart/values.yaml`](mongodb-chart/values.yaml). Änderungen lassen sich in einer eigenen Werte-Datei bündeln, zum Beispiel `my-values.yaml`, und mit `-f my-values.yaml` übergeben. Geheimnisse gehören nicht in diese Datei.

Vor einer Installation kann Helm die resultierenden Kubernetes-Ressourcen anzeigen:

```bash
helm template mongodb ./mongodb-chart --namespace mongodb -f my-values.yaml \
  --set auth.vaultPath=secret/data/mongodb/auth
```

Wichtige anpassbare Werte:

| Bereich | Werte und Zweck |
|---|---|
| Namen | `nameOverride`, `fullnameOverride` ändern die Chart- und Ressourcennamen. |
| Replica Set | `replicaSet.name` setzt den Replica-Set-Namen; `replicaSet.members` legt die Mitgliederzahl fest. |
| MongoDB-Image | `image.repository`, `image.tag`, `image.pullPolicy` wählen Image und Abrufverhalten. |
| TLS | `tls.enabled` muss aktiviert bleiben; `tls.memberSecrets` ordnet jedem Pod sein TLS-Secret zu. |
| Anmeldung | `auth.username`, `auth.vaultPath`, `auth.vaultRole`, `auth.serviceAccountName` konfigurieren MongoDB-Benutzer sowie Vault Agent und ServiceAccount. |
| Interne Anmeldung | `internalAuth.existingSecret`, `internalAuth.keyFileKey` bestimmen Secret und Schlüssel für die Replica-Set-Keyfile. |
| Datenvolumes | `storage.size`, `storage.storageClassName`, `storage.accessModes` konfigurieren die Daten-PVCs. |
| Service | `service.port` ändert den Service-Port. |
| Ressourcen | `capacityAllocation.total` teilt das Gesamtbudget auf die MongoDB-Pods auf; bei deaktivierter Teilung gelten `resources.requests` und `resources.limits` je Pod. |
| Platzierung | `nodeSelector`, `tolerations`, `affinity`, `podAnnotations` und `topologySpread` beeinflussen die Pod-Platzierung und Metadaten. |
| Backups | `backup.enabled`, `backup.schedule`, `backup.timeZone`, `backup.retentionDays` und `backup.storage` steuern Sicherungen. |
| Wiederherstellung | `restore.enabled`, `restore.archiveFile`, `restore.database`, `restore.fullRestore` steuern einen Restore-Job. |

Beispiel für eine Vorschau mit eigenen Ressourcen, Speichergröße und Sicherungszeit:

```bash
helm template mongodb ./mongodb-chart --namespace mongodb \
  --set storage.size=15Gi \
  --set capacityAllocation.total.requests.cpuMilli=1800 \
  --set capacityAllocation.total.requests.memoryMi=2304 \
  --set-string backup.schedule="15 4 * * *"
```

PowerShell verwendet `\` nicht als Zeilenfortsetzung. Dasselbe Beispiel dort als einzelne Zeile:

```powershell
helm template mongodb .\mongodb-chart --namespace mongodb --set storage.size=15Gi --set capacityAllocation.total.requests.cpuMilli=1800 --set capacityAllocation.total.requests.memoryMi=2304 --set-string backup.schedule="15 4 * * *"
```

Ein bereits initialisiertes Replica Set lässt sich nicht gefahrlos durch bloßes Ändern von `replicaSet.members` skalieren. Für zusätzliche Mitglieder braucht es passende Zertifikate und eine kontrollierte Replica-Set-Konfigurationsänderung. Außerdem sind Änderungen am unveränderlichen `StatefulSet`-Selector nicht per normalem Helm-Upgrade möglich.

## Secrets und Passwörter

Das MongoDB-Administratorpasswort wird in Vault KV v2 unter `secret/mongodb/auth`,
Feld `password`, gespeichert. Der Vault Agent Injector authentifiziert sich mit
dem ServiceAccount `mongodb-vault-reader` und rendert den Wert zur Pod-Startzeit
als Datei nach `/vault/secrets/admin-password`. Helm erhält den Passwortwert
nicht als Value.

Beim Wechsel von einer früheren Chart-Version, die das Passwort als Helm-Value
gespeichert hat, mit `--reset-values` aktualisieren und ausschließlich
nicht-geheime Overrides erneut übergeben. `--reuse-values` könnte alte Werte in
die neue Helm-Revision übernehmen. Frühere Helm-Revisionen können den alten
Wert weiterhin enthalten; Hinweise zur History-Bereinigung stehen in
[`vault/README.md`](vault/README.md).

Der Wert wird nicht als Kubernetes-Secret angelegt. Er ist zur Laufzeit dennoch
im Vault-Agent-Volume und im Prozess des berechtigten Containers vorhanden;
Zugriff auf Pods, Container und Vault-Rolle muss daher eingeschränkt werden.
Der Agent aktualisiert die Datei nicht laufend. Passwortrotation muss mit einer
Änderung in MongoDB, dem Update des Vault-Werts und einem Pod-Neustart
koordiniert werden.

Das Chart benötigt weiterhin folgende Kubernetes-Secrets im selben Namespace wie MongoDB:

| Kubernetes-Secret | Schlüssel | Inhalt |
|---|---|---|
| `mongodb-internal-auth` | `keyfile` | Gemeinsamer Schlüssel für die interne Replica-Set-Anmeldung |
| `mongo-0-tls`, `mongo-1-tls`, `mongo-2-tls` | `tls.crt`, `tls.key`, `ca.crt` | Zertifikat, privater Schlüssel und CA je Mitglied |

Die Namen und Schlüssel lassen sich über `internalAuth` und `tls.memberSecrets` ändern. Vault-Pfad, Vault-Rolle und ServiceAccount sind über `auth.vaultPath`, `auth.vaultRole` und `auth.serviceAccountName` konfigurierbar.

### Herkunft der übrigen Secrets

Wenn Vault Secrets Operator eingerichtet ist, liegen Keyfile und TLS-Werte in Vault KV v2 und werden als Kubernetes-Secrets synchronisiert:

| Vault-Pfad | Ziel im Kubernetes-Cluster |
|---|---|
| `secret/mongodb/auth` | Vault Agent rendert `password` direkt in die Pods |
| `secret/mongodb/internal-auth` | `mongodb-internal-auth` mit `keyfile` |
| `secret/mongodb/tls/mongo-0` | `mongo-0-tls` |
| `secret/mongodb/tls/mongo-1` | `mongo-1-tls` |
| `secret/mongodb/tls/mongo-2` | `mongo-2-tls` |

Die TLS-Werte im Vault-Pfad verwenden die Schlüssel `tls.crt`, `tls.key` und `ca.crt`. Die zugehörigen `VaultStaticSecret`-Ressourcen sind in `vault/vso-mongodb.yaml` beschrieben. Der Status kann ohne Ausgabe der geheimen Inhalte kontrolliert werden:

```bash
kubectl --context=minikube get vaultstaticsecrets -n mongodb
```

### Administratorpasswort ändern

Ein Vault-Update ändert nicht das in MongoDB gespeicherte Passwort. Ändere den
Benutzer zuerst in MongoDB über eine authentifizierte Verbindung zur Primary,
zum Beispiel interaktiv mit
`db.getSiblingDB("admin").changeUserPassword("admin", passwordPrompt())`.
Aktualisiere danach das Feld `password` in `secret/mongodb/auth` über Vault UI
oder einen autorisierten Vault-Client. Starte anschließend das StatefulSet neu,
damit der Vault Agent das neue Passwort für die Pods rendert:

```bash
kubectl rollout restart statefulset/mongodb -n mongodb
kubectl rollout status statefulset/mongodb -n mongodb --timeout=5m
```

Neue Bootstrap-, Backup- und Restore-Pods lesen beim Start den aktuellen
Vault-Wert. Die Rotation muss geplant werden, damit MongoDB und Vault
zwischenzeitlich nicht unterschiedliche Passwörter verwenden.

Das lokale Demo-Vault ist im Entwicklungsmodus mit In-Memory-Speicher eingerichtet. Ein Neustart kann die dort gespeicherten Werte löschen. Es ist nicht für produktive Geheimnisverwaltung geeignet. Für produktive Nutzung muss Vault mit dauerhaftem Speicher, geeigneter Authentifizierung, TLS und gesicherter Entsiegelung konfiguriert werden.

## Backups und Wiederherstellung

Backups sind standardmäßig aktiviert. Der CronJob erstellt täglich um 03:00 Uhr in der Zeitzone `Europe/Zurich` ein komprimiertes MongoDB-Archiv. Die Dateien liegen auf einem separaten Backup-PVC, standardmäßig mit 20 GiB. Backups werden nach 30 Tagen gelöscht. Zeitplan, Zeitzone, Aufbewahrungsdauer und PVC sind über `backup.*` anpassbar.

### Manuelles Backup (macOS/Linux)

Ein manuelles Backup lässt sich aus dem CronJob erstellen:

```bash
kubectl create job mongodb-backup-manual \
  --from=cronjob/mongodb-backup \
  -n mongodb
kubectl logs job/mongodb-backup-manual -n mongodb
```

Der Job muss erfolgreich mit `Complete` enden. `0/1 Completed` bei seinem Pod ist normal: Der Einmal-Container ist beendet; entscheidend ist der Jobstatus `Complete` und der erfolgreiche Logeintrag „Backup erstellt“.

Die Archive liegen auf dem PVC `mongodb-backups` unter `/backups`. Das PVC gehört zum Kubernetes-Cluster, in dem das Backup erstellt wurde. Wähle deshalb denselben Kubernetes-Kontext wie beim Backup. Bei der bisherigen lokalen Installation war das meist `minikube`; das Mehrknotenprofil heißt `mongodb-multinode` und hat ein eigenes Backup-Volume.

### Backup-Dateien anzeigen (macOS/Linux)

Aus dem Projektordner kannst du einen kurzlebigen Pod starten, der das Backup-Volume einbindet:

```bash
kubectl --context=minikube run backup-list -n mongodb \
  --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"backup-list","image":"busybox:1.36","command":["sh","-c","ls -lh /backups"],"volumeMounts":[{"name":"backups","mountPath":"/backups"}]}],"volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"mongodb-backups"}}]}}'
kubectl --context=minikube get pod backup-list -n mongodb
kubectl --context=minikube logs backup-list -n mongodb
kubectl --context=minikube delete pod backup-list -n mongodb
```

Warte bei `get pod`, bis der Status `Completed` lautet, und lies dann die Logs. Die Archivdatei ist kein normales lesbares Dokument. Um ihre MongoDB-Daten zu öffnen, musst du sie in eine MongoDB-Instanz wiederherstellen.

### Manuelles Backup unter Windows (PowerShell)

```powershell
$context = "minikube"
kubectl --context $context delete job mongodb-backup-manual -n mongodb --ignore-not-found
kubectl --context $context create job mongodb-backup-manual --from=cronjob/mongodb-backup -n mongodb
kubectl --context $context get job mongodb-backup-manual -n mongodb
kubectl --context $context logs job/mongodb-backup-manual -n mongodb
```

Der Job sollte `Complete` melden. Falls du mehrere manuelle Backups nacheinander erstellst, verwende jeweils einen neuen Jobnamen oder lösche den alten Job zuerst.

### Backup-Dateien anzeigen (Windows PowerShell)

Öffne PowerShell und wechsle in den Projektordner, der `mongodb-chart` enthält, zum Beispiel:

```powershell
Set-Location "C:\Pfad\zu\mongodb-projekt"
```

Setze `$context` auf den Cluster, auf dem das Backup erstellt wurde. Der Standard ist hier `minikube`:

```powershell
$context = "minikube"
$overrides = '{"spec":{"containers":[{"name":"backup-list","image":"busybox:1.36","command":["sh","-c","ls -lh /backups"],"volumeMounts":[{"name":"backups","mountPath":"/backups"}]}],"volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"mongodb-backups"}}]}}'
kubectl --context $context run backup-list -n mongodb --image=busybox:1.36 --restart=Never --overrides=$overrides
kubectl --context $context get pod backup-list -n mongodb
kubectl --context $context logs backup-list -n mongodb
kubectl --context $context delete pod backup-list -n mongodb
```

Warte ebenfalls auf `Completed`, bevor du die Logs abrufst. Falls du eine andere Release- oder PVC-Bezeichnung verwendest, passe `mongodb-backups` im Befehl an.

Ein Backup auf demselben Cluster schützt nicht vor Verlust des Clusters oder seines Speichers; wichtige Archive zusätzlich außerhalb des Clusters sichern.

### Datenbank wiederherstellen (macOS/Linux)

Ein datenbankspezifischer Restore benötigt den Archivdateinamen und einen Datenbanknamen:

```bash
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --no-hooks \
  --set restore.enabled=true \
  --set restore.fullRestore=false \
  --set-string restore.database=backup_test \
  --set-string restore.archiveFile=mongodb-YYYYMMDDTHHMMSSZ.archive.gz
```

### Vollständige Wiederherstellung (macOS/Linux)

Für eine vollständige Wiederherstellung wird `restore.fullRestore=true` gesetzt und kein Datenbankname angegeben:

```bash
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --no-hooks \
  --set restore.enabled=true \
  --set restore.fullRestore=true \
  --set-string restore.archiveFile=mongodb-YYYYMMDDTHHMMSSZ.archive.gz
```

Der Restore verwendet `--drop` und kann vorhandene Daten überschreiben. Die Eingaben werden durch das Template geprüft: Der Archivwert muss ein Dateiname ohne Pfad sein; Datenbank-Restore und vollständiger Restore dürfen nicht gleichzeitig gewählt werden. Ein Restore-Job sollte nur nach Prüfung des Archivs und mit klarer Kenntnis des Ziels gestartet werden.

### Restore unter Windows (PowerShell)

Wechsle zuerst in den Ordner, der `mongodb-chart` enthält. Ersetze `$archive` durch einen Dateinamen aus der Backup-Liste und `$database` durch den Datenbanknamen im Archiv. Der folgende Restore spielt nur diese Datenbank in die aktuelle MongoDB-Installation ein:

```powershell
$context = "minikube"
$archive = "mongodb-YYYYMMDDTHHMMSSZ.archive.gz"
$database = "backup_test"
kubectl --context $context delete job mongodb-restore -n mongodb --ignore-not-found
helm --kube-context $context upgrade --install mongodb .\mongodb-chart --namespace mongodb --reuse-values --no-hooks --set restore.enabled=true --set restore.fullRestore=false --set-string restore.database=$database --set-string restore.archiveFile=$archive
kubectl --context $context get job mongodb-restore -n mongodb
kubectl --context $context logs job/mongodb-restore -n mongodb
```

Für einen **vollständigen Restore** verwendest du stattdessen diesen Helm-Befehl. Lasse dabei `$database` weg:

```powershell
helm --kube-context $context upgrade --install mongodb .\mongodb-chart --namespace mongodb --reuse-values --no-hooks --set restore.enabled=true --set restore.fullRestore=true --set-string restore.archiveFile=$archive
```

Restore danach deaktivieren:

```powershell
helm --kube-context $context upgrade --install mongodb .\mongodb-chart --namespace mongodb --reuse-values --no-hooks --set restore.enabled=false
```

PowerShell verwendet nicht `\` als Zeilenfortsetzung; deshalb stehen die Helm-Befehle hier jeweils in einer Zeile. `--reuse-values` übernimmt die bestehenden Helm-Werte. `--drop` löscht beim Restore vorhandene Collections im ausgewählten Ziel. Ein vollständiger Restore kann entsprechend mehr Daten ersetzen. Prüfe Archiv, Datenbank und Kontext vor dem Start. Zum Testen verwende eine getrennte Testinstanz.

Restore anschließend unter macOS/Linux wieder deaktivieren:

```bash
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --no-hooks \
  --set restore.enabled=false
```

## Kapazitätsaufteilung

Das Chart kann ein gemeinsames CPU- und RAM-Budget gleichmäßig auf die MongoDB-Hauptcontainer aufteilen. Die Werte stehen unter `capacityAllocation.total` in `mongodb-chart/values.yaml`. Standardmäßig sind das insgesamt 750m CPU und 1536 MiB Arbeitsspeicher als Requests sowie 3000m CPU und 3072 MiB als Limits. Bei drei Mitgliedern erhält jeder MongoDB-Container daraus 250m CPU und 512 MiB Request sowie 1000m CPU und 1024 MiB Limit.

Wird die Mitgliederzahl geändert, berechnet Helm die Werte je Pod neu. Nicht ganz teilbare Reste bleiben ungenutzt. Das Budget gilt für die MongoDB-Hauptcontainer; Backup-, Bootstrap- und Init-Container sind nicht darin enthalten. `capacityAllocation.enabled: false` schaltet die Teilung aus; dann gelten `resources.requests` und `resources.limits` wieder je MongoDB-Pod.

Die Aufteilung ist ein fest konfiguriertes Budget. Sie misst nicht automatisch die Hardware oder freie Kapazität eines Servers. Der Kubernetes-Scheduler entscheidet anhand der Requests und der Platzierungsregeln, auf welchen Nodes die Pods laufen. Ein laufend messender Hardware-Controller ist eine separate, noch nicht implementierte Erweiterung.

## Ressourcen und mehrere Server

Helm teilt das konfigurierte Gesamtbudget in gleiche Werte je MongoDB-Pod. Der Kubernetes-Scheduler platziert die Pods anschließend anhand ihrer Requests und der Platzierungsregeln. Ein Controller, der freie Hardware laufend misst und das Budget automatisch ändert, ist nicht enthalten.

Die Topology-Spread-Regel versucht, MongoDB-Pods über Kubernetes-Nodes zu verteilen. Mit einem Node, wie beim normalen Minikube-Profil, laufen alle drei Pods auf demselben Node. Ein Minikube-Mehrknotenprofil kann Verteilung und Failover testen, stellt aber keine drei unabhängigen physischen Server dar.

## HashiCorp Vault

Die Vault-Integration verwendet Vault KV v2, Vault Agent Injector, Vault Secrets Operator und Kubernetes-Authentifizierung. Der Agent rendert das Admin-Passwort direkt in MongoDB-, Bootstrap-, Backup- und Restore-Pods; dafür wird kein Kubernetes-Secret mit dem Admin-Passwort erstellt. VSO synchronisiert Keyfile und TLS-Material weiterhin in Kubernetes-Secrets.

Die Einrichtung steht in [`vault/README.md`](vault/README.md); Policy und Ressourcen befinden sich in `vault/mongodb-read.hcl` und `vault/vso-mongodb.yaml`. Vault Agent Injector muss vor dem Erstellen der MongoDB-Pods bereit sein. Das Dev-Vault nutzt In-Memory-Speicher und einen Demo-Root-Token und ist nur für lokale Tests geeignet. Eine Änderung in Vault rotiert nicht automatisch das bereits in MongoDB gespeicherte Passwort; Datenbank, Vault und Pod-Neustart müssen koordiniert werden.

## Prüfungen und bekannte Grenzen

Im lokalen Minikube-Setup wurden Chart-Rendering und Anpassungen, Replica-Set-Status, Neustart eines Mitglieds, Backup-Erstellung, Aufbewahrung, datenbankspezifischer Restore, vollständiger Restore in einer isolierten Testinstanz sowie die Verteilung auf drei Minikube-Nodes geprüft. Die vollständige Wiederherstellung wurde isoliert getestet, um die aktive Datenbank nicht zu überschreiben.

Die Vault-Demo synchronisiert Keyfile und TLS-Secrets über VSO; Vault Agent liefert das Admin-Passwort zur Laufzeit direkt an Pods. Ein produktiver Vault-Betrieb, produktive Schlüsselrotation, externe Backup-Speicherung und ein eigenes automatisches Kapazitätsmanagement sind nicht Teil dieses Charts.
