# Como atualizar o Atelas Client

1. Edite `www/index.html` (o app inteiro está nele).
2. Se mudar o formato dos dados, aumente `DATA_VERSION` e acrescente um passo em `migrate()`. Nunca troque `KEY` (`meudia.v1`), ou os dados salvos somem.
3. Aumente `versionCode` e `versionName` em `android/app/build.gradle` (o Android só instala por cima se o número for maior) e `APP_VERSION` em `www/index.html`.
4. Envie para o GitHub. O APK é gerado em Actions > Gerar APK > Artifacts.
5. Instale o APK por cima do antigo. Os dados continuam.

Guarde `atelas-release.jks` e `android/keystore.properties` em lugar seguro. Sem eles não dá para atualizar o app instalado. Mantenha o repositório privado.
