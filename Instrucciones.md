#Este paquete implementa una infraestructura en kubernetes, configurando un nodo Master01 y "n" cantidad de Workers. 

#Añadir usuario ansible en todos los nodos (master y workers): 
useradd -m ansible
passwd ansible
echo 'ansible ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ansible
chmod 0440 /etc/sudoers.d/ansible

#En el nodo master01 con el usuario "ansible", ejecutar estando posicionado en k8s-ansible/
ansible-galaxy collection install -r requirements.yml

ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id ansible@192.168.6.128 #ip del master
ssh-copy-id ansible@192.168.6.129 #ip del worker
...
(copiar a todos los nodos)

#Ejecutar el script para configurar ansible user, hostnames, número de workers e ip's de cada nodo: 
./k8s-ansible/setup-inventory.sh

#Ejecutar el playbook de configuración k8s-ansible/site.yml
ansible-playbook site.yml:
