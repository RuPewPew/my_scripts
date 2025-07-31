#!/bin/bash

# Проверка, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от root" 
   exit 1
fi

# Запрос имени пользователя
read -p "Введите имя нового пользователя: " username

# Проверка, что имя пользователя не пустое
if [[ -z "$username" ]]; then
    echo "Имя пользователя не может быть пустым"
    exit 1
fi

# Запрос пароля
read -s -p "Введите пароль для нового пользователя: " password
echo

# Проверка, что пароль не пустой
if [[ -z "$password" ]]; then
    echo "Пароль не может быть пустым"
    exit 1
fi

# Запрос SSH ключа
echo "Введите SSH ключ (в формате ssh-rsa AAAA... user@host):"
read -p "SSH ключ: " ssh_key

# Проверка, что SSH ключ не пустой
if [[ -z "$ssh_key" ]]; then
    echo "SSH ключ не может быть пустым"
    exit 1
fi

# Проверка формата SSH ключа (простая проверка)
if [[ ! "$ssh_key" =~ ^ssh-(rsa|dsa|ecdsa|ed25519) ]]; then
    echo "Предупреждение: Возможно неверный формат SSH ключа"
    read -p "Продолжить? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Отменено пользователем"
        exit 1
    fi
fi

# Создание пользователя с указанным паролем
useradd -m -s /bin/bash "$username"
echo "$username:$password" | chpasswd

# Добавление пользователя в группу sudo (в CentOS/RHEL используйте wheel)
if getent group sudo > /dev/null 2>&1; then
    usermod -aG sudo "$username"
elif getent group wheel > /dev/null 2>&1; then
    usermod -aG wheel "$username"
else
    echo "Группа sudo или wheel не найдена. Пользователь не добавлен в группу администраторов"
fi

# Создание директории .ssh и установка прав
home_dir="/home/$username"
ssh_dir="$home_dir/.ssh"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
chown "$username:$username" "$ssh_dir"

# Добавление SSH ключа
echo "$ssh_key" > "$ssh_dir/authorized_keys"
chmod 600 "$ssh_dir/authorized_keys"
chown "$username:$username" "$ssh_dir/authorized_keys"

echo "Пользователь $username успешно создан и SSH ключ добавлен"

# Отключение аутентификации по паролю и включение только по ключам
sshd_config="/etc/ssh/sshd_config"

# Создание бэкапа конфига
cp "$sshd_config" "${sshd_config}.backup.$(date +%Y%m%d_%H%M%S)"

# Изменение настроек SSH
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' "$sshd_config"
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' "$sshd_config"
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$sshd_config"
sed -i 's/PubkeyAuthentication no/PubkeyAuthentication yes/' "$sshd_config"

# Если строка PasswordAuthentication отсутствует, добавляем её
if ! grep -q "^PasswordAuthentication" "$sshd_config"; then
    echo "PasswordAuthentication no" >> "$sshd_config"
fi

# Если строка PubkeyAuthentication отсутствует, добавляем её
if ! grep -q "^PubkeyAuthentication" "$sshd_config"; then
    echo "PubkeyAuthentication yes" >> "$sshd_config"
fi

# Функция для перезапуска SSH с проверкой различных названий служб
restart_ssh_service() {
    # Список возможных названий служб SSH
    local ssh_services=("ssh" "sshd" "openssh-server")
    
    for service in "${ssh_services[@]}"; do
        if systemctl list-unit-files | grep -q "^$service.service"; then
            echo "Попытка перезапуска службы: $service"
            if systemctl restart "$service"; then
                echo "Служба $service успешно перезапущена"
                return 0
            else
                echo "Не удалось перезапустить службу $service"
            fi
        fi
    done
    
    # Если systemd не работает, пробуем другие методы
    if command -v service &> /dev/null; then
        echo "Попытка перезапуска через service ssh restart"
        if service ssh restart; then
            echo "SSH успешно перезапущен через service"
            return 0
        fi
        
        echo "Попытка перезапуска через service sshd restart"
        if service sshd restart; then
            echo "SSHD успешно перезапущен через service"
            return 0
        fi
    fi
    
    # Последняя попытка через init.d
    if [ -f "/etc/init.d/ssh" ]; then
        echo "Попытка перезапуска через /etc/init.d/ssh restart"
        /etc/init.d/ssh restart
        return $?
    elif [ -f "/etc/init.d/sshd" ]; then
        echo "Попытка перезапуска через /etc/init.d/sshd restart"
        /etc/init.d/sshd restart
        return $?
    fi
    
    echo "Не удалось перезапустить SSH службу любым известным способом"
    echo "Пожалуйста, перезапустите SSH вручную"
    return 1
}

# Перезапуск SSH сервиса
echo "Перезапуск SSH сервиса..."
if restart_ssh_service; then
    echo "SSH настройки обновлены: аутентификация по паролю отключена, только по ключам"
else
    echo "ПРЕДУПРЕЖДЕНИЕ: Не удалось перезапустить SSH. Изменения вступят в силу после перезапуска SSH вручную."
    echo "Вы можете перезапустить SSH вручную командой:"
    echo "  sudo systemctl restart ssh"
    echo "  или sudo service ssh restart"
    echo "  или sudo /etc/init.d/ssh restart"
fi

echo ""
echo "=== РЕЗЮМЕ ==="
echo "Пользователь: $username"
echo "Домашняя директория: $home_dir"
echo "SSH ключ добавлен: $ssh_dir/authorized_keys"
echo "Аутентификация по паролю: ОТКЛЮЧЕНА"
echo "Аутентификация по ключам: ВКЛЮЧЕНА"
echo "=============="
