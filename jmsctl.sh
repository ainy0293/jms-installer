#!/usr/bin/env bash
#
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

cd "${PROJECT_DIR}" || exit 1

. "${PROJECT_DIR}/scripts/utils.sh"

action=${1-}
target=${2-}
args=("$@")

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "$(gettext 'Configuration file not found'): ${CONFIG_FILE}"
    echo "$(gettext 'If you are upgrading from v1.5.x, please copy the config.txt To') ${CONFIG_FILE}"
    return 3
  fi
  if [[ -f .env ]]; then
    if ! ls -l .env | grep "${CONFIG_FILE}" &>/dev/null; then
      echo ".env $(gettext 'There is a problem with the soft connection, Please update it again')"
      rm -f .env
    fi
  fi

  if [[ ! -f .env ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi
}

function pre_check() {
  check_config_file || return 3
}

function usage() {
  echo "$(gettext 'JumpServer Deployment Management Script')"
  echo
  echo "Usage: "
  echo "  ./jmsctl.sh [COMMAND] [ARGS...]"
  echo "  ./jmsctl.sh --help"
  echo
  echo "Installation Commands: "
  echo "  install           $(gettext 'Install JumpServer')"
  echo "  upgrade [version] $(gettext 'Upgrade JumpServer')"
  echo "  check_update      $(gettext 'Check for updates JumpServer')"
  echo "  reconfig          $(gettext 'Reconfiguration JumpServer')"
  echo
  echo "Management Commands: "
  echo "  start             $(gettext 'Start   JumpServer')"
  echo "  stop              $(gettext 'Stop    JumpServer')"
  echo "  close             $(gettext 'Close   JumpServer')"
  echo "  restart           $(gettext 'Restart JumpServer')"
  echo "  status            $(gettext 'Check   JumpServer')"
  echo "  down              $(gettext 'Offline JumpServer')"
  echo "  uninstall         $(gettext 'Uninstall JumpServer')"
  echo
  echo "More Commands: "
  echo "  load_image        $(gettext 'Loading docker image')"
  echo "  backup_db         $(gettext 'Backup database')"
  echo "  restore_db [file] $(gettext 'Data recovery through database backup file')"
  echo "  raw               $(gettext 'Execute the original docker-compose command')"
  echo "  tail [service]    $(gettext 'View log')"
  echo
}

function service_to_docker_name() {
  service=$1
  if [[ "${service:0:3}" != "jms" ]]; then
    service=jms_${service}
  fi
  echo "${service}"
}

EXE=""

function start() {
  # 在执行restart动作的时候，由于 EXE 变量只会获取一次，
  # 所以在前面stop的时候添加了 docker-compose-lb.yml，
  # 若 USB_LB=0 的情况下，docker-compose-lb.yml 和 docker-compose-web-external.yml
  # 同时去 up -d 则端口冲突
  # 把它再删掉，避免端口冲突
  use_lb=$(get_config USE_LB)
  if [[ "${use_lb}" == "0" && "${EXE}" =~ "lb" ]]; then
    EXE=$(echo -n ${EXE} | sed 's/\-f\ compose\/docker\-compose\-lb\.yml//')
  fi
  ${EXE} up -d
}

function stop() {
  if [[ -n "${target}" ]]; then
    ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    return
  fi
  services=$(get_docker_compose_services ignore_db)
  # 在配置文件中，USB_LB=0的时候，判断 jms_lb容器是否在运行。
  # 若在运行，就将它关闭掉
  use_lb=$(get_config USE_LB)
  lb_container=$(docker ps -a | grep -w jms_lb)

  if [[ "${use_lb}" == "0" && -n "${lb_container}" ]]; then
    EXE+=' -f compose/docker-compose-lb.yml'
  fi
    # for i in ${services}; do
    ${EXE} stop
    # done
    # 停止和删除容器，可以直接stop，无需用循环带服务名。
    # 对于停止单个容器的情况，上方已有 target 变量判断
    # for i in ${services}; do
    ${EXE} rm -f >/dev/null
    # done
}

function close() {
  if [[ -n "${target}" ]]; then
    ${EXE} stop "${target}"
    return
  fi
  services=$(get_docker_compose_services ignore_db)
  for i in ${services}; do
    ${EXE} stop "${i}"
  done
}

function pull() {
   if [[ -n "${target}" ]]; then
    ${EXE} pull "${target}"
    return
  fi
  ${EXE} pull
}

function restart() {
  stop
  echo -e "\n"
  start
}

function check_update() {
  current_version=$(get_current_version)
  latest_version=$(get_latest_version)
  if [[ "${current_version}" == "${latest_version}" ]]; then
    echo_green "$(gettext 'The current version is up to date'): ${latest_version}"
    echo
    return
  fi
  if [[ -n "${latest_version}" ]] && [[ ${latest_version} =~ v.* ]]; then
    echo -e "\033[32m$(gettext 'The latest version is'): ${latest_version}\033[0m"
  else
    exit 1
  fi
  echo -e "$(gettext 'The current version is'): ${current_version}"
  Install_DIR="$(cd "$(dirname "${PROJECT_DIR}")" >/dev/null 2>&1 && pwd)"
  if [[ ! -d "${Install_DIR}/jumpserver-installer-${latest_version}" ]]; then
    if [[ ! -f "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz" ]]; then
      timeout 60s wget -qO "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz" "https://github.com/jumpserver/installer/releases/download/${latest_version}/jumpserver-installer-${latest_version}.tar.gz" || {
        rm -f "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz"
        timeout 60s wget -qO "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz" "https://demo.jumpserver.org/download/installer/${latest_version}/jumpserver-installer-${latest_version}.tar.gz" || {
          rm -f "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz"
          exit 1
        }
      }
    fi
    tar -xf "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz" -C "${Install_DIR}" || {
      rm -rf "${Install_DIR}/jumpserver-installer-${latest_version}" "${Install_DIR}/jumpserver-installer-${latest_version}.tar.gz"
      exit 1
    }
  fi
  cd "${Install_DIR}/jumpserver-installer-${latest_version}" || exit 1
  echo
  ./jmsctl.sh upgrade "${latest_version}"
}

function main() {
  if [[ "${OS}" == 'Darwin' ]]; then
    echo
    echo "$(gettext 'Unsupported Operating System Error')"
    echo "$(gettext 'macOS installer please see'): https://github.com/jumpserver/Dockerfile"
    exit 0
  fi
  if [[ "${OS}" =~ MINGW.* ]]; then
    echo
    echo "$(gettext 'Unsupported Operating System Error')"
    echo "$(gettext 'Windows installer please see'): https://github.com/jumpserver/Dockerfile"
    exit 0
  fi

  if [[ "${action}" == "help" || "${action}" == "h" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    echo ""
  elif [[ "${action}" == "install" || "${action}" == "reconfig" ]]; then
    echo ""
  else
    pre_check || return 3
    EXE=$(get_docker_compose_cmd_line)
  fi
  case "${action}" in
  install)
    bash "${SCRIPT_DIR}/4_install_jumpserver.sh"
    ;;
  upgrade)
    bash "${SCRIPT_DIR}/7_upgrade.sh" "$target"
    ;;
  check_update)
    check_update
    ;;
  reconfig)
    ${EXE} down -v
    bash "${SCRIPT_DIR}/1_config_jumpserver.sh"
    ;;
  start)
    start
    ;;
  restart)
    restart
    ;;
  stop)
    stop
    ;;
  pull)
    pull
    ;;
  close)
    close
    ;;
  status)
    ${EXE} ps
    ;;
  down)
    if [[ -z "${target}" ]]; then
      ${EXE} down -v
    else
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    fi
    ;;
  uninstall)
    bash "${SCRIPT_DIR}/8_uninstall.sh"
    ;;
  backup_db)
    bash "${SCRIPT_DIR}/5_db_backup.sh"
    ;;
  restore_db)
    bash "${SCRIPT_DIR}/6_db_restore.sh" "$target"
    ;;
  load_image)
    bash "${SCRIPT_DIR}/3_load_images.sh"
    ;;
  pull_images)
    pull_images
    ;;
  cmd)
    echo "${EXE}"
    ;;
  tail)
    if [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name "${target}")
      docker logs -f "${docker_name}" --tail 100
    fi
    ;;
  show_services)
    get_docker_compose_services
    ;;
  init_db)
    perform_db_migrations
    ;;
  raw)
    ${EXE} "${args[@]:1}"
    ;;
  version)
    get_current_version
    ;;
  help)
    usage
    ;;
  --help)
    usage
    ;;
  -h)
    usage
    ;;
  *)
    echo "No such command: ${action}"
    usage
    ;;
  esac
}

main "$@"
