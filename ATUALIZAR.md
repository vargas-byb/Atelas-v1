# Como atualizar o Atelas Client

1. Edite `index.html` (o app inteiro está nele). Para mudar o formato dos dados, aumente `DATA_VERSION` e acrescente um passo em `migrate()`. Nunca troque `KEY` (`meudia.v1`).
2. Aumente `APP_VERSION` no `index.html` e `versionCode`/`versionName` dentro do `build.sh` (o Android só instala por cima se o número for maior).
3. Envie para o GitHub. O APK é gerado em Actions > Gerar APK do Atelas Client > Artifacts.
4. Instale o APK por cima do antigo. Os dados continuam.

Guarde `atelas-release.jks` e `keystore.properties`. Sem eles não dá para atualizar o app instalado. Mantenha o repositório privado.
