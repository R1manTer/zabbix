#!/bin/bash

# Кольори для виводу
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}1. Оновлення системи та встановлення залежностей...${NC}"
sudo apt update && sudo apt install -y ca-certificates curl gnupg

echo -e "${GREEN}2. Додавання GPG-ключа Docker...${NC}"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL [https://download.docker.com/linux/ubuntu/gpg](https://download.docker.com/linux/ubuntu/gpg) | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo -e "${GREEN}3. Налаштування репозиторію...${NC}"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] [https://download.docker.com/linux/ubuntu](https://download.docker.com/linux/ubuntu) \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo -e "${GREEN}4. Встановлення Docker та Docker Compose...${NC}"
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo -e "${GREEN}5. Додавання користувача $USER до групи docker...${NC}"
sudo usermod -aG docker $USER

echo -e "${GREEN}6. Ввімкнення автозапуску сервісів...${NC}"
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

echo -e "${GREEN}Готово! Перезавантажте сесію або викона```

### Як запустити цей скрипт:

1.  **Зробіть файл виконуваним:**
    ```bash
    chmod +x install_docker.sh
    ```
2.  **Запустіть його:**
    ```bash
    ./install_docker.sh
    ```

---

### Що цей скрипт робить "під капотом":йте: newgrp docker${NC}"
docker --version
docker compose version
