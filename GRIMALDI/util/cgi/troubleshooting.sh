#!/bin/sh

function check_fs() {
    echo -e  "Verifico che il file system sia integro e correttamente funzionante\n"
    echo -e  "Creo file di test\n"
    touch test_file && echo -e "Ok. \n" || echo "ERRORE READONLY FS"
    rm test_file    
}

function list_connected() {
    echo -e  "Lista di tutti gli utenti connessi:\n"
    chilli_query list | busybox awk '
    function hms(sec) {               # secondi  → hh:mm:ss
        h = int(sec / 3600)
        m = int((sec % 3600) / 60)
        s = sec % 60
        return sprintf("%02d:%02d:%02d", h, m, s)
    }
    function mib(bytes) {             # byte → MiB con 1 decimale
        return sprintf("%.1f", bytes / 1048576)
    }

    BEGIN {
        fmt = "%-17s %-15s %-12s %-9s %-9s %-9s %-9s %-11s\n"
        printf fmt, "MAC", "IP", "UTENTE", "UPTIME", "LIM_T", "RX(MB)", "TX(MB)", "LIM_MB"
        printf fmt, "-----------------", "---------------", "------------",
                    "---------", "---------", "---------", "---------", "-----------"
    }

    $3=="pass" && $5==1 {             # solo sessioni autenticate & attive
        split($7, t, "/")             # t[1]=sec usati , t[2]=limite sec
        split($9, rx, "/")            # rx[1]=byte ricevuti
        split($10, tx, "/")           # tx[1]=byte inviati
        limitB = ($11 > 0) ? $11 : 0  # max total octet (0 = illimitato)

        printf fmt, $1, $2, $6,                     \
                  hms(t[1]), hms(t[2]),            \
                  mib(rx[1]), mib(tx[1]),          \
                  (limitB ? mib(limitB) : "∞")
    }'

}

function list_devices() {
    echo -e "Lista di tutti i dispositivi connessi:\n"
    chilli_query list 
}


function check_redirect() {

  chilli_query logout ip 192.168.182.254
  echo -e "Questo test simula un utente connesso al wifi e verifica che venga reindirizzato verso la pagina di login.\n"	
  echo -e "Verifico il redirect verso la pagina di login dal container CP-Check... \n"

  if ping -c 1 10.10.10.110 &>/dev/null && ping -c 1 192.168.182.254 &>/dev/null; then
    res=$(curl "http://10.10.10.110:8000/check_status?url=http://google.com" -s)
    echo -e "Il risultato è: $res\n\n"
    echo -e "ATTENZIONE: in caso di false ritentare diverse volte. La satuazione di banda potrebbe influire."
  else
    echo "Impossibile eseguire il ping al container, è acceso e raggiungibile?"
  fi
}

function login_test_user() {
  ip_radius=$(uci get chilli.@chilli[0].radiusserver1)
  echo -e "Tento il ping verso radius server...\n"

  if ! ping -c 2 $ip_radius &>/dev/null; then 
    echo "Errore: Non riesco a raggiungere il radius server"
    exit 1
  fi
  echo -e "Radius raggiunto.\n"
  echo -e "Tento login del container con utente mario.r ...\n"
  
  chilli_query login ip 192.168.182.254 username mario.r password mario.r
  sleep 2
  output=$(chilli_query list | grep 'mario.r')
  
  if echo "$output" | grep -q 'pass'; then
    echo -e "L'utente mario.r è correttamente loggato.\n"
    
    echo -e "Tento ping da container di test CP-Check...\n"
    ping=$(curl "http://10.10.10.110:8000/check_ping" -s)
    echo -e "$ping\n"
    echo -e "Tento logout...\n"
    chilli_query logout ip 192.168.182.254 username mario.r
    sleep 2 
    new_output=$(chilli_query list | grep 'mario.r')
    if echo "$new_output" | grep -q 'dnat'; then
      echo "Logout riuscito: l'utente mario.r è ora in stato 'dnat'."
    else
      echo "Errore: il logout non ha modificato lo stato come previsto."
    fi
  elif echo "$output" | grep -q 'dnat'; then
    echo "Errore nel login dell'utente mario.r."
  else
    echo "Errore: potrebbe esserci un errore nel container. Attendi un minuto e riprova."
  fi
}

function wifi_user_management_login_test() {
 # Verifica numero parametri


    USERNAME="$1"
    PASSWORD="$2"
    URL="$3"

 RESPONSE="$(curl -sS "https://${URL}/api/authentication" \
        -X POST \
        -H "User-Agent: Mozilla/5.0" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Content-Type: multipart/form-data" \
        -F "username=${USERNAME}" \
        -F "password=${PASSWORD}" \
        -c cookies.txt)"

    # Analisi del JSON (senza dipendenze esterne: uso di grep)
    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo "✅  Autenticazione riuscita per utente '${USERNAME}'."
        return 0
    elif echo "$RESPONSE" | grep -q '"Authentication failed"'; then
        echo "❌  Errore: credenziali non valide." >&2
        return 2
    else
        echo "⚠️  Risposta inattesa dal server:" >&2
        echo "$RESPONSE" >&2
        echo "Se l'errore è 403 allora significa che il proxy non sta consentendo la connessione a ${URL}." 
        return 3
    fi
}

function update_ip_proxy() {
    echo -e "Aggiorno IP del proxy...\n"
    /bin/sh /opt/update_ip_proxy.sh
}

# Controllo dell'argomento passato
case "$1" in
  connected)
    list_connected
    ;;
  redirect)
    check_redirect
    ;;
  devices)
    list_devices
    ;;
  login_test)
    login_test_user 
    ;;
  wifi_user_management_login_test)
      if [ "$#" -ne 4 ]; then
        echo "Uso:  wifi_user_management_login_test() <username> <password> <url>"
        echo "Esempio:"
        echo "   master_ecpa EUROCARGOpalermo10 hotspot-grimaldi.tpz-services.com"
        return 1
    fi
    wifi_user_management_login_test "$2" "$3" "$4"
    ;;
  check_fs)
   check_fs
   ;;
   update_ip_proxy)
   update_ip_proxy
   ;;
  *)
    echo "Argomento non valido. Usa connected, redirect, devices, login test."
    ;;
esac

