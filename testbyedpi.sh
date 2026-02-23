#!/bin/bash

PROXY_PATH=./ciadpi # путь к byedpi

# список стратегий и тестируемых сайтов:
# https://github.com/romanvht/ByeByeDPI/tree/master/app/src/main/assets

# Подробный вывод (0 или 1)
VERBOSE=0
# Пытаемся подключиться не дольше TIMEOUT секунд (2-х секунд достаточно)
TIMEOUT=2
# Количество тестов для каждого сайта
COUNT=3
# Порт на котором будет слушать byedpi (1024-65535)
PORT=10803
# Включает в curl опцию "следовать редиректу"
REDIRECT=

# ** Опции вывода результата **
# Выводить только стратегии без количества успешных проверок
#OUTPUT_STRATS_ONLY=0
# Выводить только те стратегии у которых не меньше OUTPUT_MIN_SUCCESSFUL процента успешных проверок
OUTPUT_MIN_SUCCESSFUL=0 # 0 - выводить все стратегии, 50 - только те стратегии у которых больше или равно 50% успеха
# Записывать результат (только стратегии без количества успешных проверок) в указанный файл
OUTPUT_FILE=

HELP="Использование: $0 [ПАРАМЕТР]… [ФАЙЛ_СТРАТЕГИЙ] [ФАЙЛ_САЙТОВ]…
ФАЙЛ_СТРАТЕГИЙ - файл со списком стратегий (обязателен, если не используется параметр -a)
ВНИМАНИЕ! Если задан параметр -a, то указывать ФАЙЛ_СТРАТЕГИЙ не нужно.
ФАЙЛ_САЙТОВ - файл со списком сайтов (обязателен, если не используется параметр -s)

Опции:
  -a params     задает стратегию в коммандной строке вместо файла, можно
                указать опцию несколько раз (заключайте стратегию в кавычки)
  -s site       задает тестируемый сайт в коммандной строке вместо файла, можно
                указать опцию несколько раз
  -b path       путь к byedpi (по умолчанию $PROXY_PATH)
  -c count      количество проверок каждого сайта (по умолчанию $COUNT)
  -t seconds    максимальное время ожидания ответа сайта в секундах (по умолчанию $TIMEOUT)
  -p port       порт, на котором будет работать byedpi (по умолчанию $PORT)
  -L            включить в curl опцию -L (следовать редиректу)
  -m percent    минимальный процент; выводить только те стратегии,
                результат которых больше или равен указанному значению;
                может принимать значения от 0 до 100 (по умолчанию $OUTPUT_MIN_SUCCESSFUL)
  -o file       файл, в который будет записан результат проверок (только стратегии)
  -v            выводить подробную информацию
  -h            показать справку и выйти
"

# Список стратегий
STRATS_ARRAY=()
# Список тестируемых сайтов
SITES_ARRAY=()

# Парсим ключи
TOTAL_STRATS=0
while getopts "a:s:b:c:t:p:Lm:o:vh" opt; do
    case $opt in
        a) STRATS_ARRAY+=("$OPTARG"); ((TOTAL_STRATS++)) ;;
        s) SITES_ARRAY+=("$OPTARG") ;;
        b) PROXY_PATH="$OPTARG" ;;
        c) COUNT="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        L) REDIRECT="-L" ;;
        m) OUTPUT_MIN_SUCCESSFUL="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        v) VERBOSE=1 ;;
        h) echo "$HELP"; exit 0 ;;
        *) echo "Используйте $0 -h для дополнительной информации."; exit 1 ;;
    esac
done

# Удаляем обработанные ключи из списка аргументов ($@)
shift $((OPTIND - 1))

if ((TOTAL_STRATS==0)); then
    # Если -a не было, берем список стратегий из файла
    # Читаем файл (удаляем комментарии и пустые строки)
    mapfile -t STRATS_ARRAY < <(sed 's/#.*//; /^[[:space:]]*$/d' "$1")
    shift
    TOTAL_STRATS=${#STRATS_ARRAY[@]}
fi

# Читаем список сайтов из файла
while (($# != 0)); do
    [[ -f "$1" ]] || { echo "$0: $1: файл не найден"; exit 1; }
    mapfile -t ar < <(sed 's/#.*//; s/[[:space:]]/\n/g' "$1" | sed '/^$/d')
    SITES_ARRAY+=("${ar[@]}")
    shift
done

if ((${#STRATS_ARRAY[@]} == 0)); then
    echo "Пустой список стратегий"; exit 1;
fi
if ((${#SITES_ARRAY[@]} == 0)); then
    echo "Пустой список сайтов"; exit 1;
fi

# Количество проверок каждой стратегии
((NUM_TESTS = ${#SITES_ARRAY[@]} * COUNT))

# проверка наличия byedpi
if ! command -v $PROXY_PATH > /dev/null; then
    echo "$0: byedpi не найден"; exit 1
fi

# Адрес на котором слушает byedpi
PROXY_ADDR="socks5://127.0.0.1:$PORT"
# Либо, если нужно, чтобы DNS тоже шел через прокси:
# PROXY_ADDR="socks5h://127.0.0.1:$PORT"

# Временный файл для сохранения результатов проверки
tmpfile=$(mktemp)
# Удалить временный файл после завершения/прерывания скрипта
trap 'rm -f "$tmpfile"' EXIT

# Количество проверенных стратегий
NUM_STRATS=0

for STRAT in "${STRATS_ARRAY[@]}"; do
    SUCCESSFUL=0 # Количество успешных проверок
    ((NUM_STRATS++))
    echo -e "$NUM_STRATS/$TOTAL_STRATS Запуск с параметрами: \e[0;36m$STRAT\e[0m"

    # Запуск программы-прокси в фоне
    if [[ $VERBOSE == 1 ]]; then
        $PROXY_PATH -i 127.0.0.1 -p $PORT $STRAT &
    else
        $PROXY_PATH -i 127.0.0.1 -p $PORT $STRAT > /dev/null 2>&1 &
    fi
    PROXY_PID=$!
    if [[ $VERBOSE == 1 ]]; then
        echo "Прокси (PID $PROXY_PID) запущен."
    fi

    # Даем программе секунду, чтобы она успела открыть порт
    sleep 1
    # Проверяем запустился ли прокси
    if ! kill -0 $PROXY_PID 2>/dev/null; then
        echo "Прокси не стартовал. Возможно ошибка в аргументах. Переходим к следующей стратегии"
        continue
    fi

    for SITE in "${SITES_ARRAY[@]}"; do
        if [[ $VERBOSE == 1 ]]; then
            echo "Проверка $SITE через $PROXY_ADDR"
        else
            echo -n "  ${SITE}: "
        fi
        for ((i=0; i<COUNT; i++)); do
            # Проверка доступности сайта через прокси
            # -x: задает адрес прокси
            # -s: "silent" режим (скрыть прогресс-бар)
            # -o /dev/null: не выводить тело страницы в терминал
            # -w: вывести только код ответа HTTP
            # -S: включает показ ошибок, когда -s выключил их
            # -L: следовать редиректу
            # 2>&1 перенаправляет текст ошибки в ту же переменную, где лежит код ответа
            start=$(date +%s%3N) # в миллисекундах
            # Выполняем запрос
            RESULT=$(curl -s -S $REDIRECT -o /dev/null -w "%{http_code}" \
                          --max-time $TIMEOUT \
                          -x "$PROXY_ADDR" "https://$SITE" 2>&1)
            end=$(date +%s%3N)
            ((time = end-start))

            # Проверяем результат
            if [[ "$RESULT" == "200" ]]; then
                # код HTTP 200
                if [[ $VERBOSE == 1 ]]; then
                    echo -e "\e[1;32mУспех:\e[0m time: $time ms."
                else
                    echo -n "$time "
                fi
                ((SUCCESSFUL++))
            elif [[ "$RESULT" =~ ^[0-9]{3}$ ]]; then
                # $RESULT состоит из 3-х цифр
                # другой код HTTP
                if [[ $VERBOSE == 1 ]]; then
                    echo "Код ответа HTTP: $RESULT"
                    echo "time: $time ms."
                else
                    echo -n "$time[${RESULT}] "
                fi
                ((SUCCESSFUL++))
            elif [[ "$RESULT" =~ "Operation timed out" ]]; then
                # curl сообщил о превышении максимального времени ответа
                if [[ $VERBOSE == 1 ]]; then
                    # "${RESULT%???}" - отрезаем три последних символа (код http)
                    echo -ne "\e[0;33m${RESULT%???}\e[0m"
                    echo "Код ответа HTTP: ${RESULT: -3}"
                    echo "time: $time ms."
                else
                    echo -n "$time[timeout] "
                fi
            else
                # какая-то ошибка
                if [[ $VERBOSE == 1 ]]; then
                    echo -ne "\e[0;33m${RESULT%???}\e[0m"
                    echo "Код ответа HTTP: ${RESULT: -3}"
                    echo "time: $time ms."
                else
                    echo -n "$time[error] "
                fi
            fi
        done
        echo

    done

    echo  -e "\e[1;32m$SUCCESSFUL из $NUM_TESTS пройдено\e[0m"
    echo "$SUCCESSFUL $STRAT" >> $tmpfile


    # Останавливаем прокси после проверки
    kill $PROXY_PID
    wait $PROXY_PID
    if [[ $VERBOSE == 1 ]]; then
        echo "Прокси (PID $PROXY_PID) остановлен."
    fi

    echo "------------------------"

done

# Сортируем результаты по количеству успешных проверок
((min_successful = NUM_TESTS*OUTPUT_MIN_SUCCESSFUL/100))
sort -n $tmpfile | while read -r first rest; do
    if ((first >= min_successful)); then
        echo -e "\e[1;32m${first}/$NUM_TESTS\e[0m $rest"
        if [[ -n "$OUTPUT_FILE" ]]; then
            echo "$rest" >> "$OUTPUT_FILE"
        fi
    fi
done

