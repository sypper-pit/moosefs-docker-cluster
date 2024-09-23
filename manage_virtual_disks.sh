#!/bin/bash

# Скрипт: manage_virtual_disks.sh
# Описание: Создает и монтирует несколько виртуальных дисков с заданным размером.

# Функция для вывода информационных сообщений
info_message() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

# Функция для вывода сообщений об ошибках
error_message() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# Функция для вывода предупреждений
warning_message() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

# Функция для отображения справки
usage() {
    echo "Usage: $0 -n <number_of_disks> -s <size_per_disk> [-p <image_path>] [-m <mount_base>]"
    echo "  -n, --number       Количество создаваемых виртуальных дисков"
    echo "  -s, --size         Размер каждого виртуального диска (например, 10G, 500M)"
    echo "  -p, --path         Базовый путь для хранения образов дисков (по умолчанию: /srv/moosefs)"
    echo "  -m, --mount        Базовый путь для монтирования дисков (по умолчанию: /mnt/moosefs)"
    echo "  -h, --help         Показать эту справку и выйти"
}

# Парсинг аргументов командной строки
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -n|--number)
    NUM_DISKS="$2"
    shift # past argument
    shift # past value
    ;;
    -s|--size)
    SIZE_PER_DISK="$2"
    shift
    shift
    ;;
    -p|--path)
    IMG_BASE_PATH="$2"
    shift
    shift
    ;;
    -m|--mount)
    MOUNT_BASE_PATH="$2"
    shift
    shift
    ;;
    -h|--help)
    usage
    exit 0
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done

# Restore positional parameters
set -- "${POSITIONAL[@]}"

# Проверка обязательных параметров
if [[ -z "$NUM_DISKS" || -z "$SIZE_PER_DISK" ]]; then
    error_message "Параметры --number и --size обязательны."
    usage
    exit 1
fi

# Установка значений по умолчанию для путей, если они не заданы
IMG_BASE_PATH=${IMG_BASE_PATH:-/srv/moosefs}
MOUNT_BASE_PATH=${MOUNT_BASE_PATH:-/mnt/moosefs}

# Проверка прав выполнения
if [[ $EUID -ne 0 ]]; then
   error_message "Этот скрипт должен быть запущен от имени root или с использованием sudo."
   exit 1
fi

# Создание базовых директорий, если они не существуют
info_message "Проверка наличия базовых директорий..."
mkdir -p "$IMG_BASE_PATH" "$MOUNT_BASE_PATH"
if [[ $? -ne 0 ]]; then
    error_message "Не удалось создать базовые директории: $IMG_BASE_PATH или $MOUNT_BASE_PATH."
    exit 1
fi
info_message "Базовые директории готовы: $IMG_BASE_PATH и $MOUNT_BASE_PATH."

# Функция для создания и монтирования виртуального диска
create_and_mount_disk() {
    local disk_num=$1
    local size=$2
    local img_path="$IMG_BASE_PATH/virtual_disk${disk_num}.img"
    local mount_point="$MOUNT_BASE_PATH/virtual_disk${disk_num}"

    # Шаг 1: Проверка существования образа
    if [[ -f "$img_path" ]]; then
        warning_message "Образ $img_path уже существует. Пропускаем создание."
    else
        info_message "Создаем образ виртуального диска: $img_path размером $size"
        dd if=/dev/zero of="$img_path" bs=1M count=0 seek=$(echo $size | sed 's/G/*1024/;s/M/*1/' | bc)
        if [[ $? -ne 0 ]]; then
            error_message "Не удалось создать образ $img_path."
            exit 1
        fi

        # Шаг 2: Создание файловой системы
        info_message "Создаем файловую систему ext4 на $img_path"
        mkfs.ext4 "$img_path"
        if [[ $? -ne 0 ]]; then
            error_message "Не удалось создать файловую систему на $img_path."
            exit 1
        fi
    fi

    # Шаг 3: Проверка существования точки монтирования
    if [[ ! -d "$mount_point" ]]; then
        info_message "Создаем точку монтирования: $mount_point"
        mkdir -p "$mount_point"
        if [[ $? -ne 0 ]]; then
            error_message "Не удалось создать точку монтирования $mount_point."
            exit 1
        fi
    else
        info_message "Точка монтирования уже существует: $mount_point"
    fi

    # Шаг 4: Проверка файловой системы (fsck)
    info_message "Проверка файловой системы на $img_path..."
    fsck -n "$img_path" 2>&1 | grep -q "clean"
    if [[ $? -ne 0 ]]; then
        warning_message "Файловая система на $img_path может быть повреждена. Продолжаем попытку монтирования."
    else
        info_message "Файловая система на $img_path в порядке."
    fi

    # Шаг 5: Монтирование образа
    if mountpoint -q "$mount_point"; then
        info_message "Точка монтирования $mount_point уже смонтирована."
    else
        info_message "Монтируем $img_path на $mount_point"
        mount -o loop "$img_path" "$mount_point"
        if [[ $? -ne 0 ]]; then
            error_message "Не удалось смонтировать $img_path на $mount_point."
            exit 1
        fi
    fi

    # Шаг 6: Добавление в /etc/fstab, если запись отсутствует
    fstab_entry="$img_path $mount_point ext4 loop,defaults 0 2"

    if grep -qs "$img_path" /etc/fstab; then
        warning_message "Запись для $img_path уже существует в /etc/fstab."
    else
        info_message "Добавляем запись в /etc/fstab: $fstab_entry"
        echo "$fstab_entry" >> /etc/fstab
        if [[ $? -ne 0 ]]; then
            error_message "Не удалось добавить запись в /etc/fstab."
            exit 1
        else
            info_message "Запись успешно добавлена в /etc/fstab."
        fi
    fi
}

# Цикл создания и монтирования дисков
for ((i=1; i<=NUM_DISKS; i++))
do
    create_and_mount_disk "$i" "$SIZE_PER_DISK"
done

# Применение всех изменений в /etc/fstab
info_message "Применение изменений из /etc/fstab..."
mount -a
if [[ $? -ne 0 ]]; then
    error_message "Ошибка при применении изменений из /etc/fstab."
    exit 1
else
    info_message "Изменения успешно применены."
fi

info_message "Скрипт завершен успешно!"
