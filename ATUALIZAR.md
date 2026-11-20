# Como atualizar o Atelas Client

1. Edite `index.html` (o app inteiro está nele). Para mudar o formato dos dados, aumente `DATA_VERSION` e acrescente um passo em `migrate()`. Nunca troque `KEY` (`meudia.v1`).
2. Aumente `APP_VERSION` no `index.html` e `versionCode`/`versionName` dentro do `build.sh` (o Android só instala por cima se o número for maior).
3. Envie para o GitHub. O APK é gerado em Actions > Gerar APK do Atelas Client > Artifacts.
4. Instale o APK por cima do antigo. Os dados continuam.

Guarde `atelas-release.jks` e `keystore.properties`. Sem eles não dá para atualizar o app instalado. Mantenha o repositório privado.

## Widget da tela inicial (a partir da 1.4.0)
O `build.sh` cria o widget nativo (`AtelasWidgetProvider`, `AtelasWidgetPlugin` e os XMLs). Depois de instalar o APK, abra o app uma vez, segure um espaço vazio da tela inicial do celular, toque em Widgets e escolha "Atelas Client". Ele mostra os avisos e as contas do dia e abre o app ao toque.

## Widgets e microfone
O `widgets.sh` (chamado pelo `build.sh`) cria quatro widgets: Atelas Hoje (4x2), Atelas Calendário (4x2), Atelas Saúde (2x2) e Atelas Sono (2x2). Ele também liga a permissão de microfone usada nos áudios do chat. Vídeos e áudios ficam no aparelho (IndexedDB) e não entram na cópia de segurança.

## Assistente Mibo e "Hey Mibo" (a partir da 1.3.0)
O `assistente.sh` (chamado pelo `build.sh`) baixa o modelo de voz offline (Vosk, português, ~30 MB) durante o build e cria o serviço do "Hey Mibo" e o registro da Mibo como assistente digital do Android.
- O Hey Mibo abre a Mibo numa janela translúcida por cima do app aberto (MiboOverlayActivity), como o Google Assistente. Exige "Aparecer sobre outros apps".
- Perfil > "Mibo, sua assistente": liga o Hey Mibo (notificação fixa enquanto ouve), permite aparecer sobre outros apps e define a Mibo como assistente padrão.
- Se o download do modelo falhar, o APK sai sem o Hey Mibo e o Actions mostra um aviso.
